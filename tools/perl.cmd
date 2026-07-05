@echo off
setlocal
set "ROOT=%~dp0.."
set "PERL=%ROOT%\.tools\strawberry-perl\perl\bin\perl.exe"
if not exist "%PERL%" (
  echo Portable Perl not found at "%PERL%". 1>&2
  exit /b 1
)
"%PERL%" %*
exit /b %ERRORLEVEL%
