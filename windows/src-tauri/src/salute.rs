//! La sorveglianza (come Health.swift sul Mac): IsoLR si accorge da sola quando la finestra non risponde,
//! quando un lavoro resta fermo troppo a lungo o quando l'ultima volta si è chiusa male, lo scrive nel
//! registro e al riavvio propone un rapporto in un file sul Desktop, da mandare su WhatsApp o per email.
//! Il rapporto non contiene il nome utente (C:\Users\***) né le canzoni.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Secondi senza battito della finestra prima di scriverlo nel registro.
pub const HANG_SECONDS: u64 = 5;
/// Minuti senza avanzamento di un lavoro prima di considerarlo fermo.
pub const STALL_MINUTES: u64 = 15;

static DIR: OnceLock<PathBuf> = OnceLock::new();
static LAST_BEAT: AtomicU64 = AtomicU64::new(0);
static HANG_LOGGED: AtomicBool = AtomicBool::new(false);
static ACTIVITY: Mutex<Option<(String, u64)>> = Mutex::new(None);
static STALL_LOGGED: AtomicBool = AtomicBool::new(false);
/// Finestra ridotta a icona o nascosta: i suoi orologi rallentano, il silenzio non è un blocco.
static PAUSED: AtomicBool = AtomicBool::new(false);
static FILE_LOCK: Mutex<()> = Mutex::new(());

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn stamp() -> String {
    // Ora UTC semplice (niente librerie in più): basta per mettere in fila i fatti
    let s = now();
    format!("{:02}:{:02}:{:02} UTC", (s / 3600) % 24, (s / 60) % 60, s % 60)
}

fn dir() -> Option<&'static PathBuf> {
    DIR.get()
}

pub fn log_path() -> Option<PathBuf> {
    dir().map(|d| d.join("registro.txt"))
}

fn problems_path() -> Option<PathBuf> {
    dir().map(|d| d.join("problemi.txt"))
}

fn marker_path() -> Option<PathBuf> {
    dir().map(|d| d.join("aperta.txt"))
}

fn append(path: &Path, line: &str, max: u64) {
    let _g = FILE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{line}");
    }
    // Oltre `max` byte si tiene la seconda metà
    if std::fs::metadata(path).map(|m| m.len() > max).unwrap_or(false) {
        if let Ok(data) = std::fs::read(path) {
            let half = data.len() / 2;
            let cut = data[half..].iter().position(|&b| b == b'\n').map(|p| half + p + 1).unwrap_or(half);
            let _ = std::fs::write(path, &data[cut..]);
        }
    }
}

/// Una riga nel registro (resta sul computer; esce solo dentro un rapporto che l'utente decide di mandare).
pub fn log(line: &str) {
    if let Some(p) = log_path() {
        append(&p, &format!("{}  {}", stamp(), line.replace(['\n', '\r'], " ")), 1_000_000);
    }
}

/// Un problema: nel registro e da parte per il rapporto del prossimo avvio.
pub fn problem(text: &str) {
    log(&format!("PROBLEMA: {text}"));
    if let Some(p) = problems_path() {
        append(&p, &format!("{} · {}", stamp(), text), 100_000);
    }
}

/// All'avvio: dove tenere i file, com'era finita l'ultima volta, e la sorveglianza accesa.
pub fn start(folder: PathBuf, version: &str) {
    let _ = std::fs::create_dir_all(&folder);
    if DIR.set(folder).is_err() {
        return;
    }
    if let Some(m) = marker_path() {
        if let Ok(last) = std::fs::read_to_string(&m) {
            problem(&format!(
                "L'ultima volta IsoLR non si è chiusa bene (arresto improvviso, o chiusa a forza mentre era bloccata). Era la {}",
                last.trim()
            ));
        }
        let _ = std::fs::write(&m, version);
    }
    log(&format!("IsoLR {version} avviata"));
    LAST_BEAT.store(now(), Ordering::Relaxed);
    std::thread::Builder::new()
        .name("IsoLR sorveglianza".into())
        .spawn(|| {
            let mut last_tick = now();
            loop {
                std::thread::sleep(Duration::from_secs(1));
                let t = now();
                // Il computer è stato in stop: anche la sorveglianza dormiva, non è un blocco
                if t.saturating_sub(last_tick) > 3 {
                    LAST_BEAT.store(t, Ordering::Relaxed);
                }
                last_tick = t;
                for note in check(t) {
                    problem(&note);
                }
            }
        })
        .ok();
}

/// Il controllo periodico; restituisce i problemi nuovi (separato per le prove).
pub fn check(t: u64) -> Vec<String> {
    let mut out = vec![];
    let silent = t.saturating_sub(LAST_BEAT.load(Ordering::Relaxed));
    let doing = ACTIVITY.lock().unwrap_or_else(|e| e.into_inner()).clone();
    if silent >= HANG_SECONDS && !PAUSED.load(Ordering::Relaxed) {
        if !HANG_LOGGED.swap(true, Ordering::Relaxed) {
            let what = doing.as_ref().map(|d| d.0.as_str()).unwrap_or("niente");
            out.push(format!("La finestra non risponde da {silent} secondi (stava facendo: {what})"));
        }
    } else if silent < 2 && HANG_LOGGED.swap(false, Ordering::Relaxed) {
        log("La finestra risponde di nuovo");
    }
    if let Some((what, since)) = doing {
        if t.saturating_sub(since) >= STALL_MINUTES * 60 && !STALL_LOGGED.swap(true, Ordering::Relaxed) {
            out.push(format!("Lavoro fermo da {STALL_MINUTES} minuti senza avanzare: {what}"));
        }
    }
    out
}

/// Il battito della finestra (ogni secondo): cosa sta facendo, se lavora. Un testo nuovo = il lavoro avanza.
pub fn beat(doing: Option<String>, t: u64) {
    LAST_BEAT.store(t, Ordering::Relaxed);
    let mut a = ACTIVITY.lock().unwrap_or_else(|e| e.into_inner());
    match doing {
        None => *a = None,
        Some(d) => {
            if a.as_ref().map(|x| x.0 != d).unwrap_or(true) {
                *a = Some((d, t));
                STALL_LOGGED.store(false, Ordering::Relaxed);
            }
        }
    }
}

pub fn beat_now(doing: Option<String>, hidden: bool) {
    PAUSED.store(hidden, Ordering::Relaxed);
    beat(doing, now());
}

pub fn doing() -> String {
    ACTIVITY.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|a| a.0.clone()).unwrap_or_else(|| "niente (in attesa)".into())
}

/// Chiusura normale: niente da segnalare la prossima volta.
pub fn clean_exit() {
    log("IsoLR chiusa");
    if let Some(m) = marker_path() {
        let _ = std::fs::remove_file(m);
    }
}

/// I problemi da proporre (di questa sessione e delle precedenti), poi dimenticati.
pub fn take_problems() -> Vec<String> {
    let Some(p) = problems_path() else { return vec![] };
    let _g = FILE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let text = std::fs::read_to_string(&p).unwrap_or_default();
    let _ = std::fs::remove_file(&p);
    text.lines().filter(|l| !l.trim().is_empty()).map(String::from).collect()
}

/// Le ultime righe del registro.
pub fn tail(n: usize) -> String {
    let text = log_path().and_then(|p| std::fs::read_to_string(p).ok()).unwrap_or_default();
    let lines: Vec<&str> = text.lines().collect();
    lines[lines.len().saturating_sub(n)..].join("\n")
}

/// Toglie il nome utente: C:\Users\Nicolò De Santis\… → C:\Users\***\… (anche con / e in minuscolo).
pub fn redact(text: &str, profile: &str, user: &str) -> String {
    let mut t = text.to_string();
    for p in [profile.to_string(), profile.replace('\\', "/")] {
        if p.len() > 3 {
            t = replace_ci(&t, &p, if p.contains('/') { "C:/Users/***" } else { "C:\\Users\\***" });
        }
    }
    for sep in ['\\', '/'] {
        let key = format!("Users{sep}");
        let mut out = String::new();
        let mut rest = t.as_str();
        while let Some(i) = find_ci(rest, &key) {
            out.push_str(&rest[..i + key.len()]);
            let after = &rest[i + key.len()..];
            let end = after.find(|c: char| c == '\\' || c == '/' || c == '"' || c == '\n' || c == '\'').unwrap_or(after.len());
            out.push_str(if after[..end] == *"***" { "***" } else { "***" });
            rest = &after[end..];
        }
        out.push_str(rest);
        t = out;
    }
    if user.chars().count() >= 3 {
        t = replace_ci(&t, user, "***");
    }
    t
}

fn find_ci(hay: &str, needle: &str) -> Option<usize> {
    let h = hay.to_lowercase();
    let n = needle.to_lowercase();
    // to_lowercase può cambiare le lunghezze solo per lettere rare: se succede si cerca così com'è
    if h.len() != hay.len() {
        return hay.find(needle);
    }
    h.find(&n)
}

fn replace_ci(hay: &str, needle: &str, with: &str) -> String {
    let mut out = String::new();
    let mut rest = hay;
    while let Some(i) = find_ci(rest, needle) {
        out.push_str(&rest[..i]);
        out.push_str(with);
        rest = &rest[i + needle.len()..];
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_user_with_accents_and_spaces() {
        let t = redact(
            r#"Apro C:\Users\Nicolò De Santis\Music\IsoLR\canzone.wav e c:/users/Nicolò De Santis/OneDrive/Desktop, poi C:\Users\altro\x"#,
            r"C:\Users\Nicolò De Santis",
            "Nicolò De Santis",
        );
        assert!(!t.contains("Nicolò"), "{t}");
        assert!(t.contains(r"C:\Users\***\Music\IsoLR\canzone.wav"), "{t}");
        assert!(!t.contains("altro"), "{t}");
    }

    #[test]
    fn hang_and_stall_are_noticed_once() {
        beat(Some("separa «Prova» in Massima (12%)".into()), 1000);
        assert!(check(1002).is_empty());
        let notes = check(1006);
        assert!(notes.iter().any(|n| n.contains("non risponde") && n.contains("Massima")), "{notes:?}");
        assert!(check(1007).iter().all(|n| !n.contains("non risponde")), "una volta sola");
        beat(Some("separa «Prova» in Massima (12%)".into()), 1008);
        let later = 1000 + STALL_MINUTES * 60 + 1;
        beat(Some("separa «Prova» in Massima (12%)".into()), later);
        assert!(check(later).iter().any(|n| n.contains("fermo")));
        beat(None, later + 1);
        assert!(check(later + 1).is_empty());
    }
}
