// Il calcolo dei modelli grandi (RoFormer di Massima e Studio) fuori dalla finestra: ONNX Runtime vero,
// con DirectML (la scheda grafica, qualsiasi marca) e il processore come riserva.
// Nella finestra (onnxruntime-web) non si poteva: sul processore il limite è 4 GB e un pezzo da 8 s della
// voce di Studio ne chiede 8,6; su WebGPU la 1.19 sbaglia una divisione del modello voce.
// onnxruntime.dll e DirectML.dll sono accanto a IsoLR.exe (dal pacchetto NuGet, vedi windows.yml).
use ort::execution_providers::{CPUExecutionProvider, DirectMLExecutionProvider};
use ort::session::{builder::GraphOptimizationLevel, Session};
use ort::value::Tensor;
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};

/// Un modello aperto, e dove calcola.
pub struct Net {
    // Ogni modello ha il suo lucchetto: chiuderlo o chiedere dove calcola non aspetta un pezzo in corso
    session: Arc<Mutex<Session>>,
    pub backend: &'static str,
    level: usize,
}

static NETS: OnceLock<Mutex<HashMap<String, Net>>> = OnceLock::new();
static INIT: OnceLock<Result<(), String>> = OnceLock::new();
/// Perché la scheda grafica non ha aperto l'ultimo modello (per il registro e «Segnala»).
static GPU_ERROR: Mutex<Option<String>> = Mutex::new(None);

/// L'ultimo motivo per cui DirectML non ha aperto un modello, se c'è.
pub fn gpu_error() -> Option<String> {
    GPU_ERROR.lock().unwrap().clone()
}

fn nets() -> &'static Mutex<HashMap<String, Net>> {
    NETS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Carica onnxruntime.dll (una volta sola).
pub fn init(dll: &Path) -> Result<(), String> {
    INIT.get_or_init(|| {
        if !dll.exists() {
            return Err(format!("manca {}", dll.display()));
        }
        ort::init_from(dll.to_string_lossy().to_string()).with_name("IsoLR").commit().map(|_| ()).map_err(|e| e.to_string())
    })
    .clone()
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
    if let Some(n) = nets().lock().unwrap().get(name) {
        return Ok(n.backend);
    }
    let mut level = from.min(CPU);
    let session = loop {
        match build(path, level) {
            Ok(s) => break s,
            Err(e) if level < CPU => {
                *GPU_ERROR.lock().unwrap() = Some(e.to_string());
                level = CPU;
            }
            Err(e) => return Err(format!("non riesco ad aprire il modello: {e}")),
        }
    };
    let backend = LEVELS[level];
    nets().lock().unwrap().insert(name.to_string(), Net { session: Arc::new(Mutex::new(session)), backend, level });
    Ok(backend)
}

/// Il modello ha dato un risultato sbagliato: si riapre al gradino dopo (solo questo modello).
/// Torna il gradino nuovo, o un errore se era già sul processore.
pub fn downgrade(name: &str, path: &Path) -> Result<(usize, &'static str), String> {
    let level = nets().lock().unwrap().get(name).map(|n| n.level).ok_or("modello non aperto")?;
    if level >= CPU {
        return Err("risultato non plausibile anche sul processore".into());
    }
    release(name);
    let backend = load(name, path, level + 1)?;
    Ok((nets().lock().unwrap().get(name).map(|n| n.level).unwrap_or(CPU), backend))
}

/// Dove calcola un modello aperto.
pub fn backend(name: &str) -> Option<&'static str> {
    nets().lock().unwrap().get(name).map(|n| n.backend)
}

/// Chiude un modello (la memoria torna libera).
pub fn release(name: &str) {
    nets().lock().unwrap().remove(name);
}

/// Un pezzo: x [1, frames, feats] → la prima uscita (la maschera), come byte f32.
/// Se la scheda grafica sbaglia, il modello si riapre sul processore e il pezzo si rifà.
pub fn run(name: &str, path: &Path, x: Vec<f32>, frames: usize, feats: usize) -> Result<(Vec<u8>, &'static str), String> {
    let first = run_once(name, &x, frames, feats);
    match first {
        Ok(v) => Ok(v),
        Err(e) => {
            let on_gpu = nets().lock().unwrap().get(name).map(|n| n.level < CPU).unwrap_or(false);
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
        let map = nets().lock().unwrap();
        let net = map.get(name).ok_or("modello non aperto")?;
        (net.session.clone(), net.backend)
    };
    let mut session = session.lock().unwrap();
    let input = Tensor::from_array(([1usize, frames, feats], x.to_vec().into_boxed_slice())).map_err(|e| e.to_string())?;
    let outputs = session.run(ort::inputs!["x" => input].map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    let (_, data) = outputs[0].try_extract_raw_tensor::<f32>().map_err(|e| e.to_string())?;
    let mut bytes = Vec::with_capacity(data.len() * 4);
    for v in data {
        bytes.extend_from_slice(&v.to_le_bytes());
    }
    Ok((bytes, backend))
}
