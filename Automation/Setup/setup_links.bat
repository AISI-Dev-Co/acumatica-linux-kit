@echo off
echo Running link setup...
fsutil behavior set SymlinkEvaluation L2R:1 R2R:1
mklink /D C:\Acumatica-ERP \\host.lan\Data
pause
