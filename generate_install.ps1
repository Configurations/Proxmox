
# Définir le répertoire à scanner (modifier si nécessaire)
$repertoire = ".\Installs"

# Définir le fichier de sortie
$fichierSortie = ".\applications.txt"

# Créer un objet StringBuilder
# Add-Type -AssemblyName "System.Text"
$stringBuilder = New-Object System.Text.StringBuilder

# Récupérer les fichiers *.sh, enlever l'extension, trier et concaténer avec des ":"
Get-ChildItem -Path $repertoire -Filter "*.sh" | 
    ForEach-Object { $_.BaseName } |  # Extraire les noms sans l'extension
    Sort-Object |                    # Trier les noms par ordre alphabétique
    ForEach-Object { 
        if ($stringBuilder.Length -gt 0) {
            $stringBuilder.Append(";") | Out-Null
        }
        $stringBuilder.Append($_) | Out-Null
    }

# Convertir le StringBuilder en chaîne de caractères et écrire dans le fichier de sortie
$stringBuilder.ToString() | Out-File -Encoding UTF8 -FilePath $fichierSortie    

# Afficher un message de confirmation
Write-Host "Liste des fichiers sans extension enregistrée dans : $fichierSortie"
