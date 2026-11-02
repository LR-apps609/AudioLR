; Clic destro su un file audio in Esplora file › «Separa con IsoLR» (per l'utente, tutti i file che Windows
; considera audio: mp3, wav, flac, m4a…). Su Windows 11 è sotto «Mostra altre opzioni».
!macro NSIS_HOOK_POSTINSTALL_MENU
  WriteRegStr HKCU "Software\Classes\SystemFileAssociations\audio\shell\IsoLR" "" "Separa con IsoLR"
  WriteRegStr HKCU "Software\Classes\SystemFileAssociations\audio\shell\IsoLR" "Icon" '"$INSTDIR\${MAINBINARYNAME}.exe",0'
  WriteRegStr HKCU "Software\Classes\SystemFileAssociations\audio\shell\IsoLR\command" "" '"$INSTDIR\${MAINBINARYNAME}.exe" "%1"'
!macroend

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
  !insertmacro NSIS_HOOK_POSTINSTALL_MENU
!macroend

; Disinstallando, la voce del clic destro va via
!macro NSIS_HOOK_PREUNINSTALL
  DeleteRegKey HKCU "Software\Classes\SystemFileAssociations\audio\shell\IsoLR"
!macroend
