// Prova «Windows pulito»: carica onnxruntime.dll come fa IsoLR e dice com'è andata, senza mai bloccarsi.
// Con le versioni fino alla 0.15, se a Windows mancava un componente (Visual C++ 2015–2022) il caricamento si
// interrompeva con un «panic» e nella finestra «Preparo il modello…» restava per sempre.
// Uso: prova_pulito <onnxruntime.dll>   Stampa «MOTORE OK» oppure «MOTORE ERRORE: <messaggio>».
#[path = "../src/nativo.rs"]
mod nativo;
use std::path::Path;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match nativo::init(Path::new(&a[1])) {
        Ok(()) => println!("MOTORE OK"),
        Err(e) => println!("MOTORE ERRORE: {e}"),
    }
}
