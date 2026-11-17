Since Minecraft doesnt ship its sounds in the Resource Packs (Also known as Texture Packs) you have to manually "extract" them from a real install. Just point this towards your Assets folder and it will do the rest

The Path you enter should Contain the "indexes" and "objects" folder.

It will then neatly spit out a folder you can put into your "Alpha" folder

Linux/macOS: `./extract.sh`
Windows (no extra installs): `powershell -ExecutionPolicy Bypass -File .\extract.ps1` (`extract.sh` also works in Git Bash)
