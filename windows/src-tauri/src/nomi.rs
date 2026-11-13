//! I nomi delle cartelle delle canzoni: senza i caratteri che Windows non accetta, non troppo lunghi e mai
//! con un punto o uno spazio in fondo. A parte da main.rs perché si prova da solo, senza compilare l'app:
//!   rustc --edition 2021 --test windows/src-tauri/src/nomi.rs -o nomi-test && ./nomi-test

pub fn clean_name(s: &str) -> String {
    let t: String = s.chars().map(|c| if "<>:\"/\\|?*".contains(c) || c.is_control() { '-' } else { c }).collect();
    // Prima si accorcia, poi si tolgono spazi e punti in fondo: Windows non accetta un nome che finisce con «.»
    let t: String = t.trim().chars().take(120).collect();
    // e anche i punti all'inizio: «...And Justice for All» diventa «And Justice for All», una cartella che non
    // si confonde con quella dell'anteprima (.anteprima) né si nasconde (dal tester t4)
    let t = t.trim_end().trim_end_matches(['.', ' ']).trim_start_matches(['.', ' ']).to_string();
    if t.is_empty() { "Canzone".into() } else { t }
}

#[cfg(test)]
mod tests {
    use super::clean_name;

    #[test]
    fn caratteri_vietati_e_vuoto() {
        assert_eq!(clean_name("AC/DC: Back?"), "AC-DC- Back-");
        assert_eq!(clean_name("   "), "Canzone");
        assert_eq!(clean_name("..."), "Canzone");
    }

    #[test]
    fn niente_punti_all_inizio() {
        // Dal tester t4: «...And Justice for All» finiva in una cartella con il punto davanti, che la libreria salta
        assert_eq!(clean_name("...And Justice for All"), "And Justice for All");
        assert_eq!(clean_name(".anteprima"), "anteprima");
        assert_eq!(clean_name(" . . Canzone"), "Canzone");
    }

    #[test]
    fn lungo_non_finisce_con_un_punto() {
        // Dal tester t20: un titolo lungo tagliato a 120 caratteri poteva finire con «.» (Windows non lo accetta)
        let t = format!("{}. resto del titolo", "a".repeat(119));
        let n = clean_name(&t);
        assert!(n.chars().count() <= 120);
        assert!(!n.ends_with('.') && !n.ends_with(' '), "finisce con {:?}", n.chars().last());
        let t = format!("{} . . . x", "b".repeat(117));
        let n = clean_name(&t);
        assert!(!n.ends_with('.') && !n.ends_with(' '));
    }
}
