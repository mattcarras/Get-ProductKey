@cd /d "%~dp0"
PowerShell -NoProfile -ExecutionPolicy Bypass -Command "& {. '.\Get-ProductKey.ps1'; Get-ProductKey -Verbose | Export-Csv '%COMPUTERNAME%_Product_Keys.csv'}"
pause
