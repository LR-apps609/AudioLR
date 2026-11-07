// IsoLR per Windows: la finestra (WebView2 + WebGPU) con l'interfaccia e il motore, e qui sotto le cose
// che una pagina da sola non può fare: file e cartelle in Musica › IsoLR, finestre di salvataggio,
// modelli scaricati e verificati, computer sveglio mentre separa, avvisi, aggiornamenti.
// La canzone non lascia mai il computer: l'unico indirizzo raggiungibile è la pagina dei rilasci su GitHub.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod finestra;
mod salute;
mod nativo;

use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_notification::NotificationExt;

const REPO: &str = "LR-apps609/AudioLR";
const BASE: &str = "https://github.com/LR-apps609/AudioLR/releases/download/modelli-windows/";
/// I modelli che si possono scaricare (nessun altro indirizzo è raggiungibile da qui).
const MODELS: &[&str] = &[
    "StrumentiSW", "VoceRevive", "VoceRoFormer9", "VoceCori3", "VoceDuetto", "BatteriaDrumSep",
    "HTDemucs", "HTDemucsFT-1", "BasicPitch", "WhisperEncoder", "WhisperDecoder",
];

/// Le cartelle scelte nelle finestre di salvataggio: solo lì (e in Musica › IsoLR) si può scrivere.
#[derive(Default)]
struct Allowed(Mutex<HashSet<PathBuf>>);

fn output_root(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().audio_dir().map_err(|e| e.to_string())?.join("IsoLR");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

fn models_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?.join("Modelli");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

/// Un percorso si può scrivere o leggere solo dentro Musica › IsoLR o dove l'utente ha scelto di salvare.
fn check(app: &AppHandle, allowed: &Allowed, path: &Path) -> Result<(), String> {
    if path.components().any(|c| matches!(c, std::path::Component::ParentDir)) {
        return Err("percorso non valido".into());
    }
    let root = output_root(app)?;
    if path.starts_with(&root) {
        return Ok(());
    }
    let ok = allowed.0.lock().unwrap().iter().any(|a| path == a || path.starts_with(a));
    if ok { Ok(()) } else { Err("IsoLR può scrivere solo in Musica › IsoLR o dove scegli tu".into()) }
}

fn clean_name(s: &str) -> String {
    let t: String = s.chars().map(|c| if "<>:\"/\\|?*".contains(c) || c.is_control() { '-' } else { c }).collect();
    let t = t.trim().trim_end_matches('.').to_string();
    if t.is_empty() { "Canzone".into() } else { t.chars().take(120).collect() }
}

#[tauri::command]
fn app_version(app: AppHandle) -> String {
    app.package_info().version.to_string()
}

#[tauri::command]
fn output_dir(app: AppHandle) -> Result<String, String> {
    Ok(output_root(&app)?.to_string_lossy().into_owned())
}

/// Una cartella nuova per la canzone: «Titolo», «Titolo 2»… (una separazione non sovrascrive mai la precedente).
#[tauri::command]
fn new_song_dir(app: AppHandle, title: String) -> Result<String, String> {
    let root = output_root(&app)?;
    let base = clean_name(&title);
    let mut dir = root.join(&base);
    let mut n = 2;
    while dir.exists() {
        dir = root.join(format!("{base} {n}"));
        n += 1;
    }
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.to_string_lossy().into_owned())
}

/// Scrive un file: il contenuto arriva così com'è (niente JSON), il percorso in un'intestazione.
#[tauri::command]
fn write_file(app: AppHandle, allowed: State<Allowed>, request: tauri::ipc::Request) -> Result<(), String> {
    let path = request.headers().get("path").and_then(|v| v.to_str().ok()).ok_or("percorso mancante")?;
    let path = PathBuf::from(urlencoding::decode(path).map_err(|e| e.to_string())?.into_owned());
    check(&app, &allowed, &path)?;
    let tauri::ipc::InvokeBody::Raw(bytes) = request.body() else { return Err("contenuto mancante".into()) };
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    // Prima un file provvisorio, poi al suo posto: un'interruzione non lascia un file a metà
    let tmp = path.with_extension("parziale");
    std::fs::write(&tmp, bytes).map_err(|e| format!("non riesco a scrivere {}: {e}", path.display()))?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

#[tauri::command]
async fn read_file(app: AppHandle, allowed: State<'_, Allowed>, path: String) -> Result<tauri::ipc::Response, String> {
    let p = PathBuf::from(&path);
    check(&app, &allowed, &p)?;
    let bytes = tauri::async_runtime::spawn_blocking(move || std::fs::read(p))
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| format!("non riesco a leggere il file: {e}"))?;
    Ok(tauri::ipc::Response::new(bytes))
}

#[tauri::command]
fn exists(path: String) -> bool {
    Path::new(&path).exists()
}

/// Nel Cestino (si può sempre recuperare).
#[tauri::command]
fn trash(app: AppHandle, allowed: State<Allowed>, path: String) -> Result<(), String> {
    let p = PathBuf::from(&path);
    check(&app, &allowed, &p)?;
    trash::delete(&p).map_err(|e| e.to_string())
}

/// Le canzoni separate: le cartelle di Musica › IsoLR che hanno un isolr.json (descrizione della separazione).
#[tauri::command]
fn library(app: AppHandle) -> Result<Vec<serde_json::Value>, String> {
    let root = output_root(&app)?;
    let mut out = vec![];
    for e in std::fs::read_dir(&root).map_err(|e| e.to_string())?.flatten() {
        // Le cartelle con il punto davanti (l'anteprima di 20 s) non sono canzoni della libreria
        if e.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let meta = e.path().join("isolr.json");
        if let Ok(text) = std::fs::read_to_string(&meta) {
            out.push(serde_json::json!({ "folder": e.path().to_string_lossy(), "meta": text }));
        }
    }
    Ok(out)
}

/// I file di una cartella con una certa estensione, i più recenti per primi.
#[tauri::command]
fn list_files(app: AppHandle, allowed: State<Allowed>, dir: String, ext: String) -> Result<Vec<String>, String> {
    let d = PathBuf::from(&dir);
    check(&app, &allowed, &d)?;
    let mut files: Vec<(std::time::SystemTime, String)> = std::fs::read_dir(&d)
        .map(|it| {
            it.flatten()
                .filter(|e| e.path().extension().map(|x| x.eq_ignore_ascii_case(&ext)).unwrap_or(false))
                .map(|e| (e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH), e.path().to_string_lossy().into_owned()))
                .collect()
        })
        .unwrap_or_default();
    files.sort_by(|a, b| b.0.cmp(&a.0));
    Ok(files.into_iter().map(|f| f.1).collect())
}

/// Dove salvare un file (finestra di Windows). La scelta diventa scrivibile.
#[tauri::command]
async fn ask_file(app: AppHandle, allowed: State<'_, Allowed>, name: String, ext: String) -> Result<Option<String>, String> {
    let picked = app.dialog().file().set_file_name(&name).add_filter(ext.to_uppercase(), &[ext.as_str()]).blocking_save_file();
    let Some(p) = picked.and_then(|f| f.into_path().ok()) else { return Ok(None) };
    allowed.0.lock().unwrap().insert(p.clone());
    Ok(Some(p.to_string_lossy().into_owned()))
}

/// In quale cartella salvare più tracce. La cartella diventa scrivibile.
#[tauri::command]
async fn ask_folder(app: AppHandle, allowed: State<'_, Allowed>) -> Result<Option<String>, String> {
    let picked = app.dialog().file().blocking_pick_folder();
    let Some(p) = picked.and_then(|f| f.into_path().ok()) else { return Ok(None) };
    allowed.0.lock().unwrap().insert(p.clone());
    Ok(Some(p.to_string_lossy().into_owned()))
}

/// Scegli una canzone da aprire. Il file diventa leggibile.
#[tauri::command]
async fn ask_open(app: AppHandle, allowed: State<'_, Allowed>) -> Result<Option<String>, String> {
    let picked = app
        .dialog()
        .file()
        .add_filter("Audio", &["mp3", "wav", "flac", "m4a", "aac", "ogg", "opus", "aiff", "aif", "wma", "mp4"])
        .blocking_pick_file();
    let Some(p) = picked.and_then(|f| f.into_path().ok()) else { return Ok(None) };
    allowed.0.lock().unwrap().insert(p.clone());
    Ok(Some(p.to_string_lossy().into_owned()))
}

/// Apre Esplora file con il file (o la cartella) selezionato.
#[tauri::command]
fn reveal(path: String) {
    #[cfg(windows)]
    {
        let _ = std::process::Command::new("explorer").arg(format!("/select,{path}")).spawn();
    }
    #[cfg(not(windows))]
    let _ = path;
}

/// Apre nel browser la segnalazione su GitHub, già compilata. Solo quella pagina: nessun altro indirizzo.
#[tauri::command]
fn open_report(url: String) -> Result<(), String> {
    if !url.starts_with("https://github.com/LR-apps609/AudioLR/issues/new?") {
        return Err("indirizzo non permesso".into());
    }
    // rundll32 apre il browser predefinito senza passare dalla riga di comando (le «&» restano intatte)
    #[cfg(windows)]
    std::process::Command::new("rundll32").args(["url.dll,FileProtocolHandler", &url]).spawn().map_err(|e| e.to_string())?;
    Ok(())
}

/// Mentre separa il computer non va in stop da solo (album di notte); lo schermo può spegnersi.
#[tauri::command]
fn keep_awake(on: bool) {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::Power::{SetThreadExecutionState, ES_CONTINUOUS, ES_SYSTEM_REQUIRED};
        SetThreadExecutionState(if on { ES_CONTINUOUS | ES_SYSTEM_REQUIRED } else { ES_CONTINUOUS });
    }
    #[cfg(not(windows))]
    let _ = on;
}

/// «Poi metti in stop il computer»: sospensione (non ibernazione).
#[tauri::command]
fn sleep_now() {
    #[cfg(windows)]
    unsafe {
        windows_sys::Win32::System::Power::SetSuspendState(0, 0, 0);
    }
}

#[tauri::command]
fn notify(app: AppHandle, title: String, body: String) -> Result<(), String> {
    app.notification().builder().title(title).body(body).show().map_err(|e| e.to_string())
}

/// La finestra dentro lo spazio utile dello schermo (senza la barra delle applicazioni): a 2560×1440 al 175–200%,
/// a 1920×1080 al 125–150% e a 1366×768 la misura di partenza (1280×820 più la barra del titolo) non ci sta.
fn fit_window(w: &tauri::Window) {
    let (Ok(Some(m)), Ok(inner), Ok(outer), Ok(pos)) = (w.current_monitor(), w.inner_size(), w.outer_size(), w.outer_position()) else {
        return;
    };
    let wa = m.work_area();
    let work = finestra::Rect { x: wa.position.x, y: wa.position.y, w: wa.size.width, h: wa.size.height };
    let scale = m.scale_factor().max(0.5);
    let chrome = ((outer.width.saturating_sub(inner.width)) as f64 / scale, (outer.height.saturating_sub(inner.height)) as f64 / scale);
    let (mw, mh) = finestra::min_size((930.0, 640.0), (work.w as f64 / scale, work.h as f64 / scale), chrome);
    let _ = w.set_min_size(Some(tauri::LogicalSize::new(mw, mh)));
    let outer = finestra::Rect { x: pos.x, y: pos.y, w: outer.width, h: outer.height };
    if let Some((iw, ih, x, y)) = finestra::fit((inner.width, inner.height), outer, work) {
        let _ = w.set_size(tauri::PhysicalSize::new(iw, ih));
        let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
    }
}

// ── Sorveglianza e rapporto senza «Segnala» (salute.rs) ──

/// Il battito della finestra, ogni secondo: se smette per 5 s la finestra è bloccata.
#[tauri::command]
async fn heartbeat(doing: Option<String>, hidden: Option<bool>) {
    salute::beat_now(doing, hidden.unwrap_or(false));
}

/// Una riga nel registro sul computer (i passi della separazione).
#[tauri::command]
async fn log_line(line: String) {
    salute::log(&line);
}

/// I problemi notati dall'ultima volta (poi dimenticati).
#[tauri::command]
async fn take_problems() -> Vec<String> {
    salute::take_problems()
}

fn user_hints() -> (String, String) {
    (std::env::var("USERPROFILE").unwrap_or_default(), std::env::var("USERNAME").unwrap_or_default())
}

/// Toglie il nome utente da un testo (anche per «Segnala», che finisce su GitHub dove è pubblico).
#[tauri::command]
async fn redact_text(text: String) -> String {
    let (profile, user) = user_hints();
    salute::redact(&text, &profile, &user)
}

/// Un valore dal registro di Windows (reg query), senza aprire finestre nere.
#[cfg(windows)]
fn reg(key: &str, value: &str) -> String {
    use std::os::windows::process::CommandExt;
    let out = std::process::Command::new("reg").args(["query", key, "/v", value]).creation_flags(0x0800_0000).output();
    let text = out.map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
    text.lines()
        .find(|l| l.trim_start().starts_with(value))
        .and_then(|l| l.split("REG_").nth(1))
        .map(|r| r.splitn(2, char::is_whitespace).nth(1).unwrap_or("").trim().to_string())
        .unwrap_or_else(|| "?".into())
}

/// Quello che la finestra non può sapere: Windows, PC, processore, memoria, disco, schermi, lingua, OneDrive.
#[tauri::command]
async fn system_facts(app: AppHandle) -> String {
    let mut lines = vec![];
    #[cfg(windows)]
    {
        let nt = r"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion";
        let build: u32 = reg(nt, "CurrentBuild").parse().unwrap_or(0);
        let name = reg(nt, "ProductName").replace("Windows 10", if build >= 22000 { "Windows 11" } else { "Windows 10" });
        lines.push(format!("{name} {} (build {build}.{})", reg(nt, "DisplayVersion"), reg(nt, "UBR")));
        let bios = r"HKLM\HARDWARE\DESCRIPTION\System\BIOS";
        lines.push(format!("PC: {} {}", reg(bios, "SystemManufacturer"), reg(bios, "SystemProductName")));
        lines.push(format!(
            "Processore: {} · architettura {}",
            reg(r"HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString"),
            std::env::var("PROCESSOR_ARCHITEW6432").or_else(|_| std::env::var("PROCESSOR_ARCHITECTURE")).unwrap_or_default()
        ));
        unsafe {
            use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
            let mut m: MEMORYSTATUSEX = std::mem::zeroed();
            m.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
            if GlobalMemoryStatusEx(&mut m) != 0 {
                lines.push(format!("Memoria: {:.1} GB, libera {:.1} GB", m.ullTotalPhys as f64 / 1e9, m.ullAvailPhys as f64 / 1e9));
            }
        }
        if let Ok(dir) = app.path().app_data_dir() {
            use std::os::windows::ffi::OsStrExt;
            use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
            let w: Vec<u16> = dir.as_os_str().encode_wide().chain(Some(0)).collect();
            let mut free = 0u64;
            if unsafe { GetDiskFreeSpaceExW(w.as_ptr(), &mut free, std::ptr::null_mut(), std::ptr::null_mut()) } != 0 {
                lines.push(format!("Spazio libero sul disco: {:.1} GB", free as f64 / 1e9));
            }
        }
        let intl = r"HKCU\Control Panel\International";
        lines.push(format!("Lingua e formato: {} · decimali «{}»", reg(intl, "LocaleName"), reg(intl, "sDecimal")));
    }
    if let Ok(ms) = app.available_monitors() {
        let list: Vec<String> = ms
            .iter()
            .enumerate()
            .map(|(i, m)| {
                let (s, wa) = (m.size(), m.work_area());
                format!(
                    "schermo {}: {}×{} al {:.0}%, spazio utile {}×{} punti",
                    i + 1,
                    s.width,
                    s.height,
                    m.scale_factor() * 100.0,
                    (wa.size.width as f64 / m.scale_factor()).round(),
                    (wa.size.height as f64 / m.scale_factor()).round()
                )
            })
            .collect();
        lines.push(format!("Schermi ({}): {}", list.len(), list.join(" · ")));
    }
    if let Some(w) = app.get_webview_window("main") {
        if let (Ok(o), Ok(f)) = (w.outer_position(), w.outer_size()) {
            lines.push(format!("Finestra: {}×{} pixel in ({}, {})", f.width, f.height, o.x, o.y));
        }
    }
    let onedrive = std::env::var("OneDrive").is_ok();
    let out = output_root(&app).map(|p| p.display().to_string()).unwrap_or_default();
    lines.push(format!(
        "Cartella delle tracce: {out}{} · OneDrive {}",
        if out.to_lowercase().contains("onedrive") { " (su OneDrive)" } else { "" },
        if onedrive { "attivo" } else { "non attivo" }
    ));
    lines.push(format!("Cosa stava facendo: {}", salute::doing()));
    lines.push(format!("Registro (ultime 150 righe):\n{}", salute::tail(150)));
    let (profile, user) = user_hints();
    salute::redact(&lines.join("\n"), &profile, &user)
}

/// Salva il rapporto sul Desktop (o in Download) e lo mostra in Esplora file. Torna il percorso.
#[tauri::command]
async fn save_report(app: AppHandle, text: String) -> Result<String, String> {
    let (profile, user) = user_hints();
    let text = salute::redact(&text, &profile, &user);
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let name = format!("Rapporto IsoLR {}.txt", secs);
    for dir in [app.path().desktop_dir(), app.path().download_dir()].into_iter().flatten() {
        let path = dir.join(&name);
        // Il Blocco note di Windows legge bene l'UTF-8 con la firma iniziale
        let mut data = vec![0xEF, 0xBB, 0xBF];
        data.extend_from_slice(text.replace('\n', "\r\n").as_bytes());
        if std::fs::write(&path, data).is_ok() {
            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                let _ = std::process::Command::new("explorer").arg(format!("/select,{}", path.display())).creation_flags(0x0800_0000).spawn();
            }
            return Ok(path.display().to_string());
        }
    }
    Err("non riesco a salvare il rapporto sul Desktop né in Download".into())
}

#[tauri::command]
fn bring_to_front(app: AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

// ── Modelli ──

/// Le connessioni verso GitHub: 15 s per collegarsi, e se per 30 s non arriva niente la lettura si ferma
/// (prima uno scaricamento poteva restare fermo per sempre senza dire niente).
fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(15))
        .timeout_read(Duration::from_secs(30))
        .user_agent("IsoLR")
        .build()
}

/// Un file piccolo (descrizione del modello, codice di controllo): fino a 3 tentativi, con attesa crescente.
fn fetch_text(url: &str) -> Result<String, String> {
    let mut last = String::new();
    for attempt in 0..3u32 {
        if attempt > 0 {
            std::thread::sleep(Duration::from_secs(2u64 << attempt));
        }
        match agent().get(url).call() {
            Ok(r) => return r.into_string().map_err(|e| format!("scaricamento interrotto: {e}")),
            Err(e) => last = e.to_string(),
        }
    }
    Err(format!("non riesco a scaricare il modello: GitHub non risponde ({last}). Serve internet solo la prima volta: controlla la connessione e premi di nuovo Separa"))
}

/// «Annulla»: ogni scaricamento di modelli partito prima di questo numero si ferma (il pezzo già arrivato resta,
/// e la volta dopo si riprende da lì).
static DOWNLOAD_EPOCH: AtomicU64 = AtomicU64::new(0);

/// Uno scaricamento alla volta per modello: se lo stesso modello è già in arrivo, si aspetta quello.
fn model_lock(name: &str) -> Arc<Mutex<()>> {
    static LOCKS: OnceLock<Mutex<HashMap<String, Arc<Mutex<()>>>>> = OnceLock::new();
    LOCKS.get_or_init(Default::default).lock().unwrap().entry(name.to_string()).or_default().clone()
}

enum Stop {
    Cancelled,
    Failed(String),
}

/// Scarica `url` in `dest` con la barra (evento `event`) e, se c'è, il codice di controllo SHA-256.
/// Il file arriva in «.parziale»: se la connessione cade si riprova fino a 3 volte (attesa crescente) e si
/// riprende da dove si era fermato (Range); il codice di controllo è sempre quello del file intero.
/// `epoch`: con un «Annulla» (DOWNLOAD_EPOCH cambiato) si ferma subito; None = non si annulla (aggiornamenti).
fn download(app: &AppHandle, url: &str, dest: &Path, sha: Option<&str>, event: &str, name: &str, epoch: Option<u64>) -> Result<(), String> {
    let tmp = dest.with_extension("parziale");
    let cancelled = || epoch.map(|e| DOWNLOAD_EPOCH.load(Ordering::SeqCst) != e).unwrap_or(false);
    let say = |status: String| {
        let _ = app.emit(event, serde_json::json!({ "name": name, "status": status }));
    };
    let mut last = String::new();
    for attempt in 1..=3u32 {
        if attempt > 1 {
            say(format!("la connessione si è interrotta, riprovo tra pochi secondi (tentativo {attempt} di 3)"));
            // Attesa crescente (2 s, poi 4 s), ma «Annulla» non aspetta
            for _ in 0..(10u32 << (attempt - 2)) {
                if cancelled() {
                    return Err("annullato".into());
                }
                std::thread::sleep(Duration::from_millis(200));
            }
        }
        match download_once(app, url, &tmp, event, name, &cancelled, &say) {
            Ok(digest) => {
                if let Some(expected) = sha {
                    if !expected.is_empty() && digest != expected {
                        let _ = std::fs::remove_file(&tmp);
                        last = "il modello scaricato non corrisponde al suo codice di controllo".into();
                        continue;
                    }
                }
                return std::fs::rename(&tmp, dest).map_err(|e| e.to_string());
            }
            Err(Stop::Cancelled) => return Err("annullato".into()),
            Err(Stop::Failed(e)) => last = e,
        }
    }
    Err(format!("non riesco a scaricare il modello: tre tentativi non sono andati a buon fine ({last}). Controlla la connessione e premi di nuovo Separa: lo scaricamento riprende da dove si è fermato"))
}

/// Un tentativo: riprende da `tmp` se c'è già un pezzo. Torna il codice SHA-256 del file intero.
fn download_once(app: &AppHandle, url: &str, tmp: &Path, event: &str, name: &str, cancelled: &dyn Fn() -> bool, say: &dyn Fn(String)) -> Result<String, Stop> {
    let failed = |e: String| Stop::Failed(e);
    let have = std::fs::metadata(tmp).map(|m| m.len()).unwrap_or(0);
    let mut req = agent().get(url);
    if have > 0 {
        req = req.set("Range", &format!("bytes={have}-"));
    }
    let resp = match req.call() {
        Ok(r) => r,
        // Il pezzo salvato non va più bene (file cambiato o già completo): si riparte da zero
        Err(ureq::Error::Status(416, _)) => {
            let _ = std::fs::remove_file(tmp);
            return Err(failed("il pezzo già scaricato non vale più, riparto da capo".into()));
        }
        Err(e) => return Err(failed(e.to_string())),
    };
    // 206 = il server riprende da dove eravamo; 200 = manda tutto il file, e si riparte da zero
    let resume = have > 0 && resp.status() == 206;
    let length: u64 = resp.header("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
    let mut hasher = Sha256::new();
    let mut file = if resume {
        // Il codice di controllo comprende anche il pezzo già arrivato
        let mut old = std::fs::File::open(tmp).map_err(|e| failed(e.to_string()))?;
        let mut buf = vec![0u8; 1 << 20];
        loop {
            let n = old.read(&mut buf).map_err(|e| failed(e.to_string()))?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            if cancelled() {
                return Err(Stop::Cancelled);
            }
        }
        say(format!("riprendo da {} MB già scaricati", have / 1_048_576));
        std::fs::OpenOptions::new().append(true).open(tmp).map_err(|e| failed(e.to_string()))?
    } else {
        std::fs::File::create(tmp).map_err(|e| failed(e.to_string()))?
    };
    let start = if resume { have } else { 0 };
    let total = if length > 0 { start + length } else { 0 };
    let mut reader = resp.into_reader();
    let mut buf = vec![0u8; 1 << 20];
    let (mut done, mut last) = (start, 0.0f64);
    loop {
        if cancelled() {
            return Err(Stop::Cancelled);
        }
        let n = reader.read(&mut buf).map_err(|e| failed(format!("scaricamento interrotto: {e}")))?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n]).map_err(|e| failed(e.to_string()))?;
        hasher.update(&buf[..n]);
        done += n as u64;
        if total > 0 {
            let p = done as f64 / total as f64;
            if p - last >= 0.005 || p >= 1.0 {
                last = p;
                let _ = app.emit(event, serde_json::json!({ "name": name, "progress": p }));
            }
        }
    }
    if total > 0 && done < total {
        return Err(failed("la connessione si è chiusa prima della fine del file".into()));
    }
    file.flush().map_err(|e| failed(e.to_string()))?;
    Ok(format!("{:x}", hasher.finalize()))
}

/// Il modello pronto sul disco: se manca si scarica (con la barra) e si verifica con il suo codice di controllo.
#[tauri::command]
async fn prepare_model(app: AppHandle, name: String) -> Result<(), String> {
    if !MODELS.contains(&name.as_str()) {
        return Err("modello sconosciuto".into());
    }
    let epoch = DOWNLOAD_EPOCH.load(Ordering::SeqCst);
    tauri::async_runtime::spawn_blocking(move || {
        let lock = model_lock(&name);
        let _one = lock.lock().unwrap_or_else(|e| e.into_inner());
        if DOWNLOAD_EPOCH.load(Ordering::SeqCst) != epoch {
            return Err("annullato".into());
        }
        let dir = models_dir(&app)?;
        let onnx = dir.join(format!("{name}.onnx"));
        let json = dir.join(format!("{name}.json"));
        if onnx.exists() && json.exists() {
            return Ok(());
        }
        if !onnx.exists() {
            let expected = fetch_text(&format!("{BASE}{name}.onnx.sha256"))?
                .split_whitespace()
                .next()
                .unwrap_or_default()
                .to_lowercase();
            download(&app, &format!("{BASE}{name}.onnx"), &onnx, Some(&expected), "model-download", &name, Some(epoch))?;
        }
        let cfg = fetch_text(&format!("{BASE}{name}.json"))?;
        std::fs::write(&json, cfg).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// «Annulla»: ferma gli scaricamenti di modelli in corso (il pezzo arrivato resta per la volta dopo).
#[tauri::command]
fn cancel_downloads() {
    DOWNLOAD_EPOCH.fetch_add(1, Ordering::SeqCst);
}

/// Il modello (o la sua descrizione) come byte, per ONNX Runtime nella finestra.
#[tauri::command]
async fn read_model(app: AppHandle, name: String, part: String) -> Result<tauri::ipc::Response, String> {
    if !MODELS.contains(&name.as_str()) || !(part == "onnx" || part == "json") {
        return Err("modello sconosciuto".into());
    }
    let path = models_dir(&app)?.join(format!("{name}.{part}"));
    let bytes = tauri::async_runtime::spawn_blocking(move || std::fs::read(path))
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| format!("modello non trovato: {e}"))?;
    Ok(tauri::ipc::Response::new(bytes))
}

/// Il percorso di un modello scaricato (solo quelli conosciuti).
fn model_path(app: &AppHandle, name: &str) -> Result<PathBuf, String> {
    if !MODELS.contains(&name) {
        return Err("modello sconosciuto".into());
    }
    Ok(models_dir(app)?.join(format!("{name}.onnx")))
}

fn native_init(app: &AppHandle) -> Result<(), String> {
    let dir = app.path().resource_dir().map_err(|e| e.to_string())?;
    nativo::init(&dir.join("onnxruntime.dll"))
}

/// Apre un modello fuori dalla finestra (scheda grafica con DirectML, o processore). Dice dove calcola.
#[tauri::command]
async fn native_load(app: AppHandle, name: String, cpu_only: bool, level: Option<usize>) -> Result<String, String> {
    native_init(&app)?;
    let path = model_path(&app, &name)?;
    let from = if cpu_only { nativo::CPU } else { level.unwrap_or(0) };
    tauri::async_runtime::spawn_blocking(move || nativo::load(&name, &path, from).map(|b| b.to_string()))
        .await
        .map_err(|e| e.to_string())?
}

/// Un pezzo nel modello: il contenuto (f32) arriva così com'è, nome e misure nelle intestazioni.
/// Torna la maschera come byte; l'intestazione della risposta non c'è, quindi il motore usato si chiede a parte.
#[tauri::command]
async fn native_run(app: AppHandle, request: tauri::ipc::Request<'_>) -> Result<tauri::ipc::Response, String> {
    let header = |k: &str| request.headers().get(k).and_then(|v| v.to_str().ok()).map(|s| s.to_string());
    let name = header("name").ok_or("nome mancante")?;
    let frames: usize = header("frames").and_then(|v| v.parse().ok()).ok_or("misure mancanti")?;
    let feats: usize = header("feats").and_then(|v| v.parse().ok()).ok_or("misure mancanti")?;
    let tauri::ipc::InvokeBody::Raw(bytes) = request.body() else { return Err("contenuto mancante".into()) };
    if bytes.len() != frames * feats * 4 {
        return Err("misure sbagliate".into());
    }
    let x: Vec<f32> = bytes.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
    let path = model_path(&app, &name)?;
    let (out, _) = tauri::async_runtime::spawn_blocking(move || nativo::run(&name, &path, x, frames, feats))
        .await
        .map_err(|e| e.to_string())??;
    Ok(tauri::ipc::Response::new(out))
}

/// Il modello ha dato un risultato sbagliato sulla scheda grafica: si riapre al gradino dopo (solo lui).
/// Torna [gradino, dove calcola].
#[tauri::command]
async fn native_downgrade(app: AppHandle, name: String) -> Result<(usize, String), String> {
    let path = model_path(&app, &name)?;
    tauri::async_runtime::spawn_blocking(move || nativo::downgrade(&name, &path).map(|(l, b)| (l, b.to_string())))
        .await
        .map_err(|e| e.to_string())?
}

/// Chiude un modello aperto fuori dalla finestra.
#[tauri::command]
async fn native_release(name: String) {
    nativo::release(&name);
}

/// «Annulla»: il pezzo in calcolo si ferma a metà e tutti i modelli aperti fuori dalla finestra si chiudono.
#[tauri::command]
async fn native_cancel() {
    nativo::cancel_all();
}

// ── Tempi in locale: una riga per separazione, solo su questo computer (mai inviata da sola) ──

fn timings_path(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.join("tempi.jsonl"))
}

/// Aggiunge una riga (JSON) al registro dei tempi; il file non supera le 500 righe.
#[tauri::command]
fn timing_add(app: AppHandle, line: String) -> Result<(), String> {
    let path = timings_path(&app)?;
    let one = line.replace(['\n', '\r'], " ");
    let mut lines: Vec<String> = std::fs::read_to_string(&path).unwrap_or_default().lines().map(String::from).collect();
    lines.push(one);
    let keep = lines.len().saturating_sub(500);
    std::fs::write(&path, lines[keep..].join("\n") + "\n").map_err(|e| e.to_string())
}

/// Le ultime `n` righe del registro dei tempi (per «Segnala», solo se l'utente manda la segnalazione).
#[tauri::command]
fn timing_last(app: AppHandle, n: usize) -> Vec<String> {
    let Ok(path) = timings_path(&app) else { return vec![] };
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let lines: Vec<String> = text.lines().filter(|l| !l.trim().is_empty()).map(String::from).collect();
    lines[lines.len().saturating_sub(n)..].to_vec()
}

/// La memoria del PC in GB. Nella finestra navigator.deviceMemory si ferma a 8 («8 o più»): con 8 GB e Studio
/// i modelli restavano aperti insieme (bug b-6). Come sul Mac: fino a 9 GB un modello alla volta.
#[tauri::command]
fn memory_gb() -> Option<f64> {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
        let mut m: MEMORYSTATUSEX = std::mem::zeroed();
        m.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
        if GlobalMemoryStatusEx(&mut m) != 0 {
            return Some(m.ullTotalPhys as f64 / (1024.0 * 1024.0 * 1024.0));
        }
    }
    None
}

/// Memoria massima usata finora (MB): IsoLR e i suoi processi WebView2 (la finestra e i lavoratori).
#[tauri::command]
fn peak_memory() -> Option<u64> {
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
        use windows_sys::Win32::System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS};
        use windows_sys::Win32::System::ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS};
        use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};
        // I processi figli (e i figli dei figli) di IsoLR
        let me = std::process::id();
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap == INVALID_HANDLE_VALUE {
            return None;
        }
        let mut pairs = vec![];
        let mut e: PROCESSENTRY32W = std::mem::zeroed();
        e.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        if Process32FirstW(snap, &mut e) != 0 {
            loop {
                pairs.push((e.th32ProcessID, e.th32ParentProcessID));
                if Process32NextW(snap, &mut e) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snap);
        let mut ours = vec![me];
        let mut i = 0;
        while i < ours.len() {
            let parent = ours[i];
            for &(pid, pp) in &pairs {
                if pp == parent && pid != parent && !ours.contains(&pid) {
                    ours.push(pid);
                }
            }
            i += 1;
        }
        let mut total: u64 = 0;
        for pid in ours {
            let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if h.is_null() {
                continue;
            }
            let mut c: PROCESS_MEMORY_COUNTERS = std::mem::zeroed();
            c.cb = std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32;
            if GetProcessMemoryInfo(h, &mut c, c.cb) != 0 {
                total += c.PeakWorkingSetSize as u64;
            }
            CloseHandle(h);
        }
        Some(total / 1_048_576)
    }
    #[cfg(not(windows))]
    None
}

/// Perché la scheda grafica non ha aperto un modello (se è successo).
#[tauri::command]
async fn native_gpu_error() -> Option<String> {
    nativo::gpu_error()
}

/// Dove sta calcolando un modello aperto (dopo un ripiego può essere cambiato).
#[tauri::command]
async fn native_backend(name: String) -> Option<String> {
    nativo::backend(&name).map(|b| b.to_string())
}

/// Quali modelli sono già sul disco.
#[tauri::command]
fn models_ready(app: AppHandle) -> Result<Vec<String>, String> {
    let dir = models_dir(&app)?;
    Ok(MODELS
        .iter()
        .filter(|n| dir.join(format!("{n}.onnx")).exists() && dir.join(format!("{n}.json")).exists())
        .map(|n| n.to_string())
        .collect())
}

// ── Aggiornamenti: i rilasci «win-vX.Y.Z» su GitHub, con l'installer dentro ──

fn newer(a: &str, b: &str) -> bool {
    let p = |s: &str| s.split('.').map(|x| x.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    p(a) > p(b)
}

/// L'ultima versione per Windows, se è più nuova di questa: { version, url, notes }.
#[tauri::command]
async fn check_update(app: AppHandle) -> Result<Option<serde_json::Value>, String> {
    let current = app.package_info().version.to_string();
    tauri::async_runtime::spawn_blocking(move || {
        let list: serde_json::Value = agent()
            .get(&format!("https://api.github.com/repos/{REPO}/releases?per_page=30"))
            .call()
            .map_err(|e| e.to_string())?
            .into_json()
            .map_err(|e| e.to_string())?;
        let mut best: Option<serde_json::Value> = None;
        for r in list.as_array().cloned().unwrap_or_default() {
            if r["draft"].as_bool() == Some(true) || r["prerelease"].as_bool() == Some(true) {
                continue;
            }
            let Some(v) = r["tag_name"].as_str().and_then(|t| t.strip_prefix("win-v")) else { continue };
            let Some(url) = r["assets"].as_array().and_then(|a| {
                a.iter().find(|x| x["name"].as_str().map(|n| n.ends_with(".exe")).unwrap_or(false))
                    .and_then(|x| x["browser_download_url"].as_str().map(String::from))
            }) else { continue };
            let better = best.as_ref().map(|b| newer(v, b["version"].as_str().unwrap_or("0"))).unwrap_or(true);
            if newer(v, &current) && better {
                best = Some(serde_json::json!({ "version": v, "url": url, "notes": r["body"].as_str().unwrap_or("") }));
            }
        }
        Ok(best)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Scarica l'installer nuovo, lo avvia e chiude IsoLR (l'installer sostituisce l'app e la riapre).
#[tauri::command]
async fn install_update(app: AppHandle, url: String) -> Result<(), String> {
    if !url.starts_with(&format!("https://github.com/{REPO}/releases/download/")) {
        return Err("indirizzo dell'aggiornamento non valido".into());
    }
    let a = app.clone();
    let exe = tauri::async_runtime::spawn_blocking(move || -> Result<PathBuf, String> {
        let dest = std::env::temp_dir().join("IsoLR-aggiornamento.exe");
        download(&a, &url, &dest, None, "update-download", "update", None)?;
        Ok(dest)
    })
    .await
    .map_err(|e| e.to_string())??;
    std::process::Command::new(exe).arg("/UPDATE").spawn().map_err(|e| e.to_string())?;
    app.exit(0);
    Ok(())
}

/// Clic destro › «Separa con IsoLR» (Esplora file): le canzoni da aprire arrivano come argomenti. Se IsoLR è già
/// aperta, la seconda copia le lascia in una cartella e si chiude; la finestra le prende da lì (take_opened).
fn inbox() -> PathBuf {
    let dir = std::env::temp_dir().join("IsoLR-apri");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn leave_for_window(files: &[String]) {
    if files.is_empty() {
        return;
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(inbox().join("da-aprire.txt")) {
        for p in files {
            let _ = writeln!(f, "{p}");
        }
    }
}

/// Le canzoni arrivate dal clic destro (e mai prese): si possono leggere, poi la lista si svuota.
#[tauri::command]
fn take_opened(allowed: State<'_, Allowed>) -> Vec<String> {
    let path = inbox().join("da-aprire.txt");
    let Ok(text) = std::fs::read_to_string(&path) else { return vec![] };
    let _ = std::fs::remove_file(&path);
    let mut out = vec![];
    for line in text.lines().map(str::trim).filter(|l| !l.is_empty()) {
        let p = PathBuf::from(line);
        if p.is_file() {
            allowed.0.lock().unwrap().insert(p.clone());
            out.push(line.to_string());
        }
    }
    out
}

fn main() {
    let files: Vec<String> = std::env::args().skip(1).filter(|a| !a.starts_with('/') && Path::new(a).is_file()).collect();
    // Una copia sola: il lucchetto resta preso finché IsoLR è aperta
    let lock = std::fs::File::create(inbox().join("istanza.lock"));
    let first = match &lock {
        Ok(f) => f.try_lock().is_ok(),
        Err(_) => true,
    };
    leave_for_window(&files);
    if !first {
        return;
    }
    let _keep = lock;
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .manage(Allowed::default())
        .setup(|app| {
            if let Ok(dir) = app.path().app_data_dir() {
                salute::start(dir.join("registro"), &app.package_info().version.to_string());
            }
            if let Some(w) = app.get_webview_window("main") {
                fit_window(&w.as_ref().window());
            }
            Ok(())
        })
        // Spostata su uno schermo con un'altra scala (o cambiata la scala): si rimette dentro lo spazio utile
        .on_window_event(|w, e| {
            if let tauri::WindowEvent::ScaleFactorChanged { .. } = e {
                fit_window(w);
            }
        })
        .invoke_handler(tauri::generate_handler![
            app_version, output_dir, new_song_dir, write_file, read_file, exists, trash, library, list_files,
            ask_file, ask_folder, ask_open, reveal, open_report, keep_awake, sleep_now, notify, bring_to_front,
            prepare_model, cancel_downloads, read_model, models_ready, check_update, install_update,
            native_cancel, timing_add, timing_last, peak_memory, memory_gb,
            native_load, native_run, native_release, native_backend, native_gpu_error, native_downgrade, take_opened,
            heartbeat, log_line, take_problems, system_facts, save_report, redact_text
        ])
        .build(tauri::generate_context!())
        .expect("IsoLR non è riuscita ad avviarsi")
        .run(|_, e| {
            // Chiusura normale: la prossima volta niente «qualcosa è andato storto»
            if let tauri::RunEvent::Exit = e {
                salute::clean_exit();
            }
        });
}
