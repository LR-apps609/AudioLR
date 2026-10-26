// AudioLR per Windows: una finestra con l'interfaccia e il motore del sito (WebView2 + WebGPU).
// Veloce ha il modello dentro l'installer. Massima e Studio scaricano i loro modelli la prima volta
// (come sul Mac), li verificano e li tengono nella cartella dell'app: poi funziona senza internet.
// La canzone non lascia mai il computer.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::path::PathBuf;
use tauri::{AppHandle, Emitter, Manager};

const BASE: &str = "https://github.com/LR-apps609/AudioLR/releases/download/modelli-windows/";
/// I modelli che si possono scaricare (nessun altro indirizzo è raggiungibile da qui).
const MODELS: &[&str] = &["StrumentiSW", "VoceRevive", "VoceRoFormer9"];

fn models_dir(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?.join("Modelli");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

fn fetch(url: &str) -> Result<ureq::Response, String> {
    ureq::get(url).call().map_err(|e| format!("non riesco a scaricare il modello (serve internet la prima volta): {e}"))
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
        let resp = fetch(&format!("{BASE}{name}.onnx"))?;
        let total: u64 = resp.header("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
        let tmp = dir.join(format!("{name}.onnx.parziale"));
        let mut file = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
        let mut reader = resp.into_reader();
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 1 << 20];
        let mut done: u64 = 0;
        let mut last = 0.0f64;
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
                    let _ = app.emit("model-download", serde_json::json!({ "name": name, "progress": p }));
                }
            }
        }
        drop(file);
        let got = format!("{:x}", hasher.finalize());
        if !expected.is_empty() && got != expected {
            let _ = std::fs::remove_file(&tmp);
            return Err("il modello scaricato è rovinato, riprova".into());
        }
        std::fs::rename(&tmp, &onnx).map_err(|e| e.to_string())?;
        let cfg = fetch(&format!("{BASE}{name}.json"))?.into_string().map_err(|e| e.to_string())?;
        std::fs::write(&json, cfg).map_err(|e| e.to_string())?;
        Ok(())
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

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![prepare_model, read_model, models_ready])
        .run(tauri::generate_context!())
        .expect("AudioLR non è riuscita ad avviarsi");
}
