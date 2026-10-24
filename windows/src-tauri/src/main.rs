// AudioLR per Windows: una finestra con l'interfaccia e il motore del sito (WebView2 + WebGPU).
// Nessuna rete: il modello è dentro l'installer, la canzone non lascia il computer.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("AudioLR non è riuscita ad avviarsi");
}
