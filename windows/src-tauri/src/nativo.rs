// Il calcolo dei modelli grandi (RoFormer di Massima e Studio) fuori dalla finestra: ONNX Runtime vero,
// con DirectML (la scheda grafica, qualsiasi marca) e il processore come riserva.
// Nella finestra (onnxruntime-web) non si poteva: sul processore il limite è 4 GB e un pezzo da 8 s della
// voce di Studio ne chiede 8,6; su WebGPU la 1.19 sbaglia una divisione del modello voce.
// onnxruntime.dll e DirectML.dll sono accanto a IsoLR.exe (dal pacchetto NuGet, vedi windows.yml).
use ort::execution_providers::{CPUExecutionProvider, DirectMLExecutionProvider};
use ort::session::{builder::GraphOptimizationLevel, run_options::RunOptions, Session};
use ort::value::Tensor;
use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

/// Un modello aperto, e dove calcola.
pub struct Net {
    // Ogni modello ha il suo lucchetto: chiuderlo o chiedere dove calcola non aspetta un pezzo in corso
    session: Arc<Mutex<Session>>,
    pub backend: &'static str,
    level: usize,
}

static NETS: OnceLock<Mutex<HashMap<String, Net>>> = OnceLock::new();
/// Riuscito una volta, vale per sempre; un errore no: dopo aver sbloccato la DLL (antivirus, quarantena) il
/// Separa dopo riprova, senza riavviare IsoLR.
static INIT: Mutex<bool> = Mutex::new(false);
/// Perché la scheda grafica non ha aperto l'ultimo modello (per il registro e «Segnala»).
static GPU_ERROR: Mutex<Option<String>> = Mutex::new(None);

/// L'ultimo motivo per cui DirectML non ha aperto un modello, se c'è.
pub fn gpu_error() -> Option<String> {
    GPU_ERROR.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

fn nets() -> &'static Mutex<HashMap<String, Net>> {
    NETS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// I pezzi in calcolo adesso (uno per modello), con il loro freno: «Annulla» li ferma a metà.
static RUNNING: OnceLock<Mutex<HashMap<String, Arc<RunOptions>>>> = OnceLock::new();
/// Cresce a ogni «Annulla»: un modello che si stava aprendo in quel momento non resta aperto.
static EPOCH: AtomicU64 = AtomicU64::new(0);

fn running() -> &'static Mutex<HashMap<String, Arc<RunOptions>>> {
    RUNNING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// «Annulla»: il pezzo in calcolo si ferma subito (ONNX Runtime controlla il freno tra un'operazione e l'altra),
/// tutti i modelli si chiudono e la memoria torna libera; un modello che si stava aprendo non resta aperto.
pub fn cancel_all() {
    EPOCH.fetch_add(1, Ordering::SeqCst);
    for r in running().lock().unwrap_or_else(|e| e.into_inner()).values() {
        let _ = r.terminate();
    }
    nets().lock().unwrap_or_else(|e| e.into_inner()).clear();
}

/// Carica onnxruntime.dll (una volta sola).
pub fn init(dll: &Path) -> Result<(), String> {
    let mut ok = INIT.lock().unwrap_or_else(|e| e.into_inner());
    if *ok {
        return Ok(());
    }
    if !dll.exists() {
        return Err(format!("manca {}", dll.display()));
    }
    // Prima la libreria da sola: se le manca un componente di Windows lo si dice (ort invece si interrompe
    // con un «panic», e la finestra aspettava per sempre «Preparo il modello…»)
    probe(dll)?;
    let path = dll.to_string_lossy().to_string();
    let r = std::panic::catch_unwind(move || ort::init_from(path).with_name("IsoLR").commit().map(|_| ()).map_err(|e| e.to_string()))
        .unwrap_or_else(|_| Err("il motore di calcolo (onnxruntime.dll) non si avvia su questo PC".into()));
    *ok = r.is_ok();
    r
}

/// Carica onnxruntime.dll con Windows, per avere un errore chiaro se non si può (componente mancante, file
/// bloccato dall'antivirus, versione sbagliata). La libreria resta caricata: ort la ritrova.
#[cfg(windows)]
fn probe(dll: &Path) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::GetLastError;
    use windows_sys::Win32::System::LibraryLoader::{LoadLibraryExW, LOAD_WITH_ALTERED_SEARCH_PATH};
    let wide: Vec<u16> = dll.as_os_str().encode_wide().chain(Some(0)).collect();
    // SAFETY: percorso terminato da zero; nessun handle da liberare (la libreria deve restare caricata)
    let handle = unsafe { LoadLibraryExW(wide.as_ptr(), std::ptr::null_mut(), LOAD_WITH_ALTERED_SEARCH_PATH) };
    if !handle.is_null() {
        return Ok(());
    }
    Err(probe_message(unsafe { GetLastError() }))
}

#[cfg(not(windows))]
fn probe(_dll: &Path) -> Result<(), String> {
    Ok(())
}

/// Il messaggio per l'errore di Windows nel caricare il motore.
pub fn probe_message(code: u32) -> String {
    match code {
        126 => "al motore di calcolo manca un componente di Windows (Microsoft Visual C++ 2015–2022)".into(),
        5 | 225 => "il motore di calcolo è bloccato (antivirus o permessi): onnxruntime.dll non si può aprire".into(),
        193 | 216 => "il motore di calcolo non è adatto a questo PC (onnxruntime.dll di un altro tipo di processore)".into(),
        _ => format!("il motore di calcolo non si carica (errore di Windows {code})"),
    }
}

/// I gradini, dal più veloce al più sicuro: scheda grafica con tutte le ottimizzazioni, scheda grafica con
/// le sole ottimizzazioni di base (alcune fusioni di operazioni su DirectML danno numeri sbagliati con
/// certi modelli), scheda grafica senza ottimizzazioni, processore.
pub const LEVELS: [&str; 4] = [
    "Scheda grafica (DirectML)",
    "Scheda grafica (DirectML, prudente)",
    "Scheda grafica (DirectML, senza ottimizzazioni)",
    "Processore",
];
pub const CPU: usize = 3;

fn build(path: &Path, level: usize) -> ort::Result<Session> {
    let opt = match level {
        1 => GraphOptimizationLevel::Level1,
        2 => GraphOptimizationLevel::Disable,
        _ => GraphOptimizationLevel::Level3,
    };
    let b = Session::builder()?.with_optimization_level(opt)?;
    if level < CPU {
        // DirectML vuole il calcolo in sequenza e senza memoria «a schema» (documentazione di ONNX Runtime)
        b.with_memory_pattern(false)?
            .with_parallel_execution(false)?
            .with_execution_providers([DirectMLExecutionProvider::default().build().error_on_failure()])?
            .commit_from_file(path)
    } else {
        b.with_execution_providers([CPUExecutionProvider::default().build()])?.commit_from_file(path)
    }
}

/// Apre un modello dal gradino `from` in giù (il primo che si apre). Dice dove calcola.
pub fn load(name: &str, path: &Path, from: usize) -> Result<&'static str, String> {
    if let Some(n) = nets().lock().unwrap_or_else(|e| e.into_inner()).get(name) {
        return Ok(n.backend);
    }
    let epoch = EPOCH.load(Ordering::SeqCst);
    let mut level = from.min(CPU);
    let session = loop {
        match build(path, level) {
            Ok(s) => break s,
            Err(e) if level < CPU => {
                *GPU_ERROR.lock().unwrap_or_else(|e| e.into_inner()) = Some(e.to_string());
                level = CPU;
            }
            Err(e) => return Err(format!("non riesco ad aprire il modello: {e}")),
        }
    };
    let backend = LEVELS[level];
    // «Annulla» mentre il modello si apriva: si richiude subito (la memoria non resta presa)
    if EPOCH.load(Ordering::SeqCst) != epoch {
        return Err("annullato".into());
    }
    nets().lock().unwrap_or_else(|e| e.into_inner()).insert(name.to_string(), Net { session: Arc::new(Mutex::new(session)), backend, level });
    Ok(backend)
}

/// Il modello ha dato un risultato sbagliato: si riapre al gradino dopo (solo questo modello).
/// Torna il gradino nuovo, o un errore se era già sul processore.
pub fn downgrade(name: &str, path: &Path) -> Result<(usize, &'static str), String> {
    let level = nets().lock().unwrap_or_else(|e| e.into_inner()).get(name).map(|n| n.level).ok_or("modello non aperto")?;
    if level >= CPU {
        return Err("risultato non plausibile anche sul processore".into());
    }
    release(name);
    let backend = load(name, path, level + 1)?;
    Ok((nets().lock().unwrap_or_else(|e| e.into_inner()).get(name).map(|n| n.level).unwrap_or(CPU), backend))
}

/// Dove calcola un modello aperto.
pub fn backend(name: &str) -> Option<&'static str> {
    nets().lock().unwrap_or_else(|e| e.into_inner()).get(name).map(|n| n.backend)
}

/// Chiude un modello (la memoria torna libera).
pub fn release(name: &str) {
    nets().lock().unwrap_or_else(|e| e.into_inner()).remove(name);
    if let Some(r) = running().lock().unwrap_or_else(|e| e.into_inner()).get(name) {
        let _ = r.terminate();
    }
}

/// Un pezzo: x [1, frames, feats] → la prima uscita (la maschera), come byte f32.
/// Se la scheda grafica sbaglia, il modello si riapre sul processore e il pezzo si rifà.
pub fn run(name: &str, path: &Path, x: Vec<f32>, frames: usize, feats: usize) -> Result<(Vec<u8>, &'static str), String> {
    let epoch = EPOCH.load(Ordering::SeqCst);
    let first = run_once(name, &x, frames, feats);
    match first {
        Ok(v) => Ok(v),
        Err(e) => {
            // Annullato nel frattempo: niente nuovo tentativo sul processore
            if EPOCH.load(Ordering::SeqCst) != epoch {
                return Err("annullato".into());
            }
            let on_gpu = nets().lock().unwrap_or_else(|e| e.into_inner()).get(name).map(|n| n.level < CPU).unwrap_or(false);
            if !on_gpu {
                return Err(e);
            }
            release(name);
            load(name, path, CPU)?;
            run_once(name, &x, frames, feats)
        }
    }
}

fn run_once(name: &str, x: &[f32], frames: usize, feats: usize) -> Result<(Vec<u8>, &'static str), String> {
    // Si prende il modello e si lascia subito l'elenco: un «Annulla» lo può chiudere mentre questo pezzo finisce
    let (session, backend) = {
        let map = nets().lock().unwrap_or_else(|e| e.into_inner());
        let net = map.get(name).ok_or("modello non aperto")?;
        (net.session.clone(), net.backend)
    };
    let session = session.lock().unwrap_or_else(|e| e.into_inner());
    // Il modello è stato chiuso mentre questo pezzo aspettava il suo turno: niente calcolo
    if !nets().lock().unwrap_or_else(|e| e.into_inner()).contains_key(name) {
        return Err("annullato".into());
    }
    let stop = Arc::new(RunOptions::new().map_err(|e| e.to_string())?);
    running().lock().unwrap_or_else(|e| e.into_inner()).insert(name.to_string(), stop.clone());
    let result = (|| {
        let input = Tensor::from_array(([1usize, frames, feats], x.to_vec().into_boxed_slice())).map_err(|e| e.to_string())?;
        let outputs = session.run_with_options(ort::inputs!["x" => input].map_err(|e| e.to_string())?, &*stop).map_err(|e| e.to_string())?;
        let (_, data) = outputs[0].try_extract_raw_tensor::<f32>().map_err(|e| e.to_string())?;
        let mut bytes = Vec::with_capacity(data.len() * 4);
        for v in data {
            bytes.extend_from_slice(&v.to_le_bytes());
        }
        Ok::<_, String>(bytes)
    })();
    running().lock().unwrap_or_else(|e| e.into_inner()).remove(name);
    Ok((result?, backend))
}
