// Prova del calcolo nativo su un Windows vero (CI): carica onnxruntime.dll, apre un RoFormer con DirectML
// (se c'è una scheda) e poi sul processore, e fa un pezzo. Uso: prova_nativo <onnxruntime.dll> <modello.onnx> <frames> <feats>
#[path = "../src/nativo.rs"]
mod nativo;
use std::path::Path;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    nativo::init(Path::new(&a[1])).expect("onnxruntime.dll");
    let model = Path::new(&a[2]);
    let (t, f): (usize, usize) = (a[3].parse().unwrap(), a[4].parse().unwrap());
    match nativo::load("gpu", model, false) {
        Ok(b) => println!("::notice::Con la scheda grafica il modello si apre su: {b}"),
        Err(e) => println!("::warning::Con la scheda grafica non si apre: {e}"),
    }
    nativo::release("gpu");
    let b = nativo::load("cpu", model, true).expect("aperto sul processore");
    let t0 = std::time::Instant::now();
    let (out, _) = nativo::run("cpu", model, vec![0.001; t * f], t, f).expect("un pezzo");
    let finite = out.chunks_exact(4).all(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]).is_finite());
    println!("::notice::Calcolo nativo su {b}: un pezzo in {:.1} s, {} valori, tutti finiti: {finite}", t0.elapsed().as_secs_f64(), out.len() / 4);
    assert!(finite && out.len() >= t * f / 4);
}
