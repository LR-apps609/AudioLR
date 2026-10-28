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
use std::sync::{Mutex, OnceLock};

/// Un modello aperto, e dove calcola.
pub struct Net {
    session: Session,
    pub backend: &'static str,
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

fn build(path: &Path, gpu: bool) -> ort::Result<Session> {
    let b = Session::builder()?.with_optimization_level(GraphOptimizationLevel::Level3)?;
    if gpu {
        // DirectML vuole il calcolo in sequenza e senza memoria «a schema» (documentazione di ONNX Runtime)
        b.with_memory_pattern(false)?
            .with_parallel_execution(false)?
            .with_execution_providers([DirectMLExecutionProvider::default().build().error_on_failure()])?
            .commit_from_file(path)
    } else {
        b.with_execution_providers([CPUExecutionProvider::default().build()])?.commit_from_file(path)
    }
}

/// Apre un modello: prima sulla scheda grafica, se non riesce sul processore. Dice dove.
pub fn load(name: &str, path: &Path, cpu_only: bool) -> Result<&'static str, String> {
    if let Some(n) = nets().lock().unwrap().get(name) {
        return Ok(n.backend);
    }
    let gpu = if cpu_only {
        None
    } else {
        match build(path, true) {
            Ok(s) => Some(s),
            Err(e) => {
                *GPU_ERROR.lock().unwrap() = Some(e.to_string());
                None
            }
        }
    };
    let (session, backend) = match gpu {
        Some(s) => (s, "Scheda grafica (DirectML)"),
        None => (build(path, false).map_err(|e| format!("non riesco ad aprire il modello: {e}"))?, "Processore"),
    };
    nets().lock().unwrap().insert(name.to_string(), Net { session, backend });
    Ok(backend)
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
            let on_gpu = nets().lock().unwrap().get(name).map(|n| n.backend != "Processore").unwrap_or(false);
            if !on_gpu {
                return Err(e);
            }
            release(name);
            load(name, path, true)?;
            run_once(name, &x, frames, feats)
        }
    }
}

fn run_once(name: &str, x: &[f32], frames: usize, feats: usize) -> Result<(Vec<u8>, &'static str), String> {
    let mut map = nets().lock().unwrap();
    let net = map.get_mut(name).ok_or("modello non aperto")?;
    let input = Tensor::from_array(([1usize, frames, feats], x.to_vec().into_boxed_slice())).map_err(|e| e.to_string())?;
    let outputs = net.session.run(ort::inputs!["x" => input].map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    let (_, data) = outputs[0].try_extract_raw_tensor::<f32>().map_err(|e| e.to_string())?;
    let mut bytes = Vec::with_capacity(data.len() * 4);
    for v in data {
        bytes.extend_from_slice(&v.to_le_bytes());
    }
    Ok((bytes, net.backend))
}
