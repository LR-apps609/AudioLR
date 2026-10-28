; Dalla 0.5 l'app si chiama IsoLR: dopo l'installazione si tolgono i resti della vecchia AudioLR
; (cartella del programma, collegamenti nel menu Start e sul desktop, voce in «App installate»).
; I dati (modelli scaricati, impostazioni) stanno altrove e restano: si usano anche con IsoLR.
!macro NSIS_HOOK_POSTINSTALL
  IfFileExists "$LOCALAPPDATA\AudioLR\*.*" 0 +2
    RMDir /r "$LOCALAPPDATA\AudioLR"
  Delete "$SMPROGRAMS\AudioLR.lnk"
  RMDir /r "$SMPROGRAMS\AudioLR"
  Delete "$DESKTOP\AudioLR.lnk"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\AudioLR"
!macroend
