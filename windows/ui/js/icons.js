// Icone a tratto (stile dei simboli del Mac), disegnate qui: niente caricato da fuori.
(function () {
  "use strict";
  const P = {
    plus: "M12 5v14M5 12h14",
    folder: "M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z",
    clock: "M12 7v5l3 2M12 3a9 9 0 1 0 0 18a9 9 0 0 0 0-18z",
    user: "M12 12a4 4 0 1 0 0-8a4 4 0 0 0 0 8zM4 20a8 8 0 0 1 16 0",
    sidebar: "M4 5h16v14H4zM9 5v14",
    help: "M12 3a9 9 0 1 0 0 18a9 9 0 0 0 0-18zM9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .8-1 1.5V14M12 17h.01",
    gear: "M12 15a3 3 0 1 0 0-6a3 3 0 0 0 0 6zM19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3a1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1-1.5a1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8a1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1a1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5a1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z",
    note: "M9 18V5l11-2v13M9 18a3 3 0 1 1-6 0a3 3 0 0 1 6 0zM20 16a3 3 0 1 1-6 0a3 3 0 0 1 6 0z",
    download: "M12 4v11M7 10l5 5l5-5M5 20h14",
    speaker: "M4 9h4l5-4v14l-5-4H4zM16 9a4 4 0 0 1 0 6",
    speakerOff: "M4 9h4l5-4v14l-5-4H4zM17 9l4 6M21 9l-4 6",
    headphones: "M4 15v-3a8 8 0 0 1 16 0v3M4 15h3v5H4zM17 15h3v5h-3z",
    mic: "M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3zM5 11a7 7 0 0 0 14 0M12 18v3",
    drum: "M4 8c0-2 3.6-3 8-3s8 1 8 3s-3.6 3-8 3s-8-1-8-3zM4 8v8c0 2 3.6 3 8 3s8-1 8-3V8M8 3l3 5M16 3l-3 5",
    bass: "M14 3l7 7M17 6l-9 9a3 3 0 1 1-3-3l9-9M8 12l4 4",
    guitar: "M15 3l6 6M18 6l-6.5 6.5M9 9a4.5 4.5 0 1 0 6 6c1-1 .5-2.5-.5-3.5S10 8 9 9z",
    piano: "M3 5h18v14H3zM8 5v9M13 5v9M18 5v9M6 14h4M11 14h4M16 14h4",
    other: "M9 18V6l10-2v12M9 18a2.5 2.5 0 1 1-5 0a2.5 2.5 0 0 1 5 0zM19 16a2.5 2.5 0 1 1-5 0a2.5 2.5 0 0 1 5 0z",
    people: "M9 11a3.5 3.5 0 1 0 0-7a3.5 3.5 0 0 0 0 7zM2 20a7 7 0 0 1 14 0M16 4a3.5 3.5 0 0 1 0 7M18 20a7 7 0 0 0-2-5",
    grid: "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
    play: "M8 5v14l11-7z",
    pause: "M7 5h4v14H7zM13 5h4v14h-4z",
    stop: "M6 6h12v12H6z",
    record: "M12 4a8 8 0 1 0 0 16a8 8 0 0 0 0-16zM12 9a3 3 0 1 0 0 6a3 3 0 0 0 0-6z",
    trash: "M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13",
    x: "M6 6l12 12M18 6L6 18",
    metronome: "M9 3h6l4 18H5zM12 17l5-9",
    count: "M12 3a9 9 0 1 0 0 18a9 9 0 0 0 0-18zM13.5 16V8l-4 5h5",
    chart: "M3 17l5-6l4 3l6-8l3 4",
    tortoise: "M4 15c0-4 3.5-7 8-7s8 3 8 7zM6 15v3M18 15v3M20 12h2",
    hare: "M4 16c2-4 6-5 10-4l4-6l1 6c2 1 3 3 2 5H4z",
    sparkle: "M12 3l2 6l6 2l-6 2l-2 6l-2-6l-6-2l6-2z",
    bolt: "M13 3L5 14h6l-1 7l8-11h-6z",
    star: "M12 3l2.7 5.6l6.1.9l-4.4 4.3l1 6.1L12 17l-5.4 2.9l1-6.1L3.2 9.5l6.1-.9z",
    info: "M12 3a9 9 0 1 0 0 18a9 9 0 0 0 0-18zM12 11v6M12 7.5h.01",
    up: "M12 19V5M6 11l6-6l6 6",
  };
  window.Icon = (name, cls = "i") => `<svg class="${cls}" viewBox="0 0 24 24" aria-hidden="true"><path d="${P[name] || P.note}"/></svg>`;
  window.IconFill = (name) => `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${P[name]}"/></svg>`;
})();
