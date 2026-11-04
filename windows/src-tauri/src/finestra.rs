//! La finestra dentro lo schermo. IsoLR si apre a 1280×820 punti più la barra del titolo, cioè circa 852:
//! su 1920×1080 al 125%, su 2560×1440 al 175% e al 200% o su 1366×768 lo spazio utile (senza la barra
//! delle applicazioni) è più basso, e la parte bassa della finestra finiva sotto la barra delle applicazioni
//! o fuori dallo schermo. Qui si calcola la misura e la posizione che ci stanno; tutto in pixel veri.

/// Un rettangolo in pixel veri: x, y, larghezza, altezza.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: u32,
    pub h: u32,
}

/// La nuova area interna (contenuto) e la posizione della finestra, se quella attuale non ci sta nello spazio utile.
/// `inner`: il contenuto (larghezza, altezza); `outer`: la finestra intera con bordi e barra del titolo, a `outer.x/y`;
/// `work`: lo spazio utile dello schermo. Restituisce None se la finestra ci sta già tutta.
pub fn fit(inner: (u32, u32), outer: Rect, work: Rect) -> Option<(u32, u32, i32, i32)> {
    let chrome_w = outer.w.saturating_sub(inner.0);
    let chrome_h = outer.h.saturating_sub(inner.1);
    let inside = outer.x >= work.x
        && outer.y >= work.y
        && outer.x + outer.w as i32 <= work.x + work.w as i32
        && outer.y + outer.h as i32 <= work.y + work.h as i32;
    if inside {
        return None;
    }
    let w = inner.0.min(work.w.saturating_sub(chrome_w)).max(1);
    let h = inner.1.min(work.h.saturating_sub(chrome_h)).max(1);
    let (ow, oh) = ((w + chrome_w) as i32, (h + chrome_h) as i32);
    // Al centro dello spazio utile, come all'apertura
    let x = work.x + (work.w as i32 - ow).max(0) / 2;
    let y = work.y + (work.h as i32 - oh).max(0) / 2;
    Some((w, h, x, y))
}

/// La misura minima (in punti) che ci sta nello spazio utile: quella di serie, o meno se lo schermo è più piccolo.
pub fn min_size(default: (f64, f64), work_points: (f64, f64), chrome_points: (f64, f64)) -> (f64, f64) {
    (default.0.min(work_points.0 - chrome_points.0).max(320.0), default.1.min(work_points.1 - chrome_points.1).max(240.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pixel veri di una finestra 1280×820 punti con la barra del titolo (32 punti) e i bordi (8 punti), a una scala.
    fn window(scale: f64, x: i32, y: i32) -> ((u32, u32), Rect) {
        let p = |v: f64| (v * scale).round() as u32;
        ((p(1280.0), p(820.0)), Rect { x, y, w: p(1280.0 + 16.0), h: p(820.0 + 32.0 + 8.0) })
    }

    /// Lo spazio utile di uno schermo: risoluzione meno la barra delle applicazioni (48 punti su Windows 11).
    fn work(w: u32, h: u32, scale: f64) -> Rect {
        Rect { x: 0, y: 0, w, h: h - (48.0 * scale).round() as u32 }
    }

    #[test]
    fn fits_already_on_full_hd_100() {
        let (inner, outer) = window(1.0, 300, 100);
        assert_eq!(fit(inner, outer, work(1920, 1080, 1.0)), None);
    }

    #[test]
    fn shrinks_on_2k_at_175_and_200() {
        for scale in [1.75, 2.0] {
            let (inner, outer) = window(scale, 0, 0);
            let wa = work(2560, 1440, scale);
            let (w, h, x, y) = fit(inner, outer, wa).expect("a questa scala la finestra non ci sta");
            let (cw, ch) = (outer.w - inner.0, outer.h - inner.1);
            assert!(h + ch <= wa.h, "scala {scale}: alta {} su {}", h + ch, wa.h);
            assert!(w + cw <= wa.w);
            assert!(x >= 0 && y >= 0 && y + (h + ch) as i32 <= wa.h as i32);
        }
    }

    #[test]
    fn shrinks_on_full_hd_125_and_1366() {
        let (inner, outer) = window(1.25, 0, 0);
        let wa = work(1920, 1080, 1.25);
        let (_, h, _, y) = fit(inner, outer, wa).unwrap();
        assert!(y + (h + outer.h - inner.1) as i32 <= wa.h as i32);
        let (inner, outer) = window(1.0, 0, 0);
        assert!(fit(inner, outer, work(1366, 768, 1.0)).is_some());
    }

    #[test]
    fn moves_back_a_window_outside_the_screen() {
        // Finestra della misura giusta ma spostata fuori (es. secondo schermo staccato)
        let (inner, outer) = window(1.0, 2500, 0);
        let (w, h, x, _) = fit(inner, outer, work(1920, 1080, 1.0)).unwrap();
        assert_eq!((w, h), inner);
        assert!(x + outer.w as i32 <= 1920);
    }

    #[test]
    fn minimum_size_follows_small_screens() {
        assert_eq!(min_size((930.0, 640.0), (1920.0, 1032.0), (16.0, 40.0)), (930.0, 640.0));
        assert_eq!(min_size((930.0, 640.0), (1280.0, 672.0), (16.0, 40.0)), (930.0, 632.0));
    }
}
