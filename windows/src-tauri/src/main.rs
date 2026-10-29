// IsoLR per Windows: la finestra (WebView2 + WebGPU) con l'interfaccia e il motore, e qui sotto le cose
// che una pagina da sola non può fare: file e cartelle in Musica › IsoLR, finestre di salvataggio,
// modelli scaricati e verificati, computer sveglio mentre separa, avvisi, aggiornamenti.
// La canzone non lascia mai il computer: l'unico indirizzo raggiungibile è la pagina dei rilasci su GitHub.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod nativo;

use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_notification::NotificationExt;

const REPO: &str = "LR-apps609/AudioLR";
const BASE: &str = "https://github.com/LR-apps609/AudioLR/releases/download/modelli-windows/";
/// I modelli che si possono scaricare (nessun altro indirizzo è raggiungibile da qui).
const MODELS: &[&str] = &[
    "StrumentiSW", "VoceRevive", "VoceRoFormer9", "VoceCori3", "VoceDuetto", "BatteriaDrumSep",
    "HTDemucs", "HTDemucsFT-1", "BasicPitch",
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

#[tauri::command]
fn bring_to_front(app: AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

// ── Modelli ──

fn fetch(url: &str) -> Result<ureq::Response, String> {
    ureq::get(url).call().map_err(|e| format!("non riesco a scaricare (serve internet la prima volta): {e}"))
}

/// Scarica `url` in `dest` con la barra (evento `event`) e, se c'è, il codice di controllo SHA-256.
fn download(app: &AppHandle, url: &str, dest: &Path, sha: Option<&str>, event: &str, name: &str) -> Result<(), String> {
    let resp = fetch(url)?;
    let total: u64 = resp.header("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
    let tmp = dest.with_extension("parziale");
    let mut file = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
    let mut reader = resp.into_reader();
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    let (mut done, mut last) = (0u64, 0.0f64);
    loop {
        let n = reader.read(&mut buf).map_err(|e| format!("scaricamento interrotto: {e}"))?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n]).map_err(|e| e.to_string())?;
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
    drop(file);
    if let Some(expected) = sha {
        let got = format!("{:x}", hasher.finalize());
        if !expected.is_empty() && got != expected {
            let _ = std::fs::remove_file(&tmp);
            return Err("il file scaricato è rovinato, riprova".into());
        }
    }
    std::fs::rename(&tmp, dest).map_err(|e| e.to_string())
}

/// Il modello pronto sul disco: se manca si scarica (con la barra) e si verifica con il suo codice di controllo.
#[tauri::command]
async fn prepare_model(app: AppHandle, name: String) -> Result<(), String> {
    if !MODELS.contains(&name.as_str()) {
        return Err("modello sconosciuto".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let dir = models_dir(&app)?;
        let onnx = dir.join(format!("{name}.onnx"));
        let json = dir.join(format!("{name}.json"));
        if onnx.exists() && json.exists() {
            return Ok(());
        }
        let expected = fetch(&format!("{BASE}{name}.onnx.sha256"))?
            .into_string()
            .map_err(|e| e.to_string())?
            .split_whitespace()
            .next()
            .unwrap_or_default()
            .to_lowercase();
        download(&app, &format!("{BASE}{name}.onnx"), &onnx, Some(&expected), "model-download", &name)?;
        let cfg = fetch(&format!("{BASE}{name}.json"))?.into_string().map_err(|e| e.to_string())?;
        std::fs::write(&json, cfg).map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
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
        let list: serde_json::Value = ureq::get(&format!("https://api.github.com/repos/{REPO}/releases?per_page=30"))
            .set("User-Agent", "IsoLR")
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
        download(&a, &url, &dest, None, "update-download", "update")?;
        Ok(dest)
    })
    .await
    .map_err(|e| e.to_string())??;
    std::process::Command::new(exe).arg("/UPDATE").spawn().map_err(|e| e.to_string())?;
    app.exit(0);
    Ok(())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .manage(Allowed::default())
        .invoke_handler(tauri::generate_handler![
            app_version, output_dir, new_song_dir, write_file, read_file, exists, trash, library, list_files,
            ask_file, ask_folder, ask_open, reveal, open_report, keep_awake, sleep_now, notify, bring_to_front,
            prepare_model, read_model, models_ready, check_update, install_update,
            native_load, native_run, native_release, native_backend, native_gpu_error, native_downgrade
        ])
        .run(tauri::generate_context!())
        .expect("IsoLR non è riuscita ad avviarsi");
}
