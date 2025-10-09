@echo off
cd /d "G:\My Drive\Game Design\25.04 - MYTHOS\MythosTCG"

REM Path to your Git installation (adjust if Git is in a different folder)
set GIT="C:\Program Files\Git\cmd\git.exe"

%GIT% add -A
%GIT% commit -m "Auto commit %date% %time%"
%GIT% push origin main

exit
