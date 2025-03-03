
# Définir le répertoire à scanner (modifier si nécessaire)
$repertoire = ".\Installs"

# Définir le fichier de sortie
$fichierSortie = ".\applications.txt"

# Récupérer les fichiers *.sh, enlever l'extension, trier et écrire dans le fichier.txt
Get-ChildItem -Path $repertoire -Filter "*.sh" | 
    ForEach-Object { $_.BaseName } | 
    Sort-Object | 
    Out-File -Encoding UTF8 -FilePath $fichierSortie

# Afficher un message de confirmation
Write-Host "Liste des fichiers sans extension enregistrée dans : $fichierSortie"
