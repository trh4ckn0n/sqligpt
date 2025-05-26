#!/bin/bash

# Chargement des variables d'environnement
source .env 2>/dev/null
OPENAI_KEY="${OPENAI_API_KEY}"

if [[ -z "$OPENAI_KEY" ]]; then
  echo -e "\033[1;31m[!] Clé OpenAI manquante dans .env (OPENAI_API_KEY=...)\033[0m"
  exit 1
fi

# Génération des noms de rapport
timestamp=$(date +%Y-%m-%d_%H-%M-%S)
report_md="report_$timestamp.md"
report_html="report_$timestamp.html"

# Demande URL et détection des paramètres
read -p "URL cible (ex: https://site.com/page.php?id=1) : " URL
PARAMS=$(echo "$URL" | grep -oP '\?\K[^#]+' | tr '&' '\n' | cut -d= -f1)

if [ -z "$PARAMS" ]; then
  echo -e "\033[1;33m[!] Aucun paramètre détecté. Mode formulaire POST.\033[0m"
  read -p "Données POST (ex: username=trkn&password=trkntrkn) : " POSTDATA
  PARAMS=$(echo "$POSTDATA" | tr '&' '\n' | cut -d= -f1)
  METHOD="POST"
else
  METHOD="GET"
fi

read -p "Cookies ? (laisser vide si aucun) : " COOKIES
read -p "User-Agent (laisser vide pour par défaut): " UA
read -p "Referer (optionnel): " REFERER

# Choix interactifs via fzf
LEVEL=$(printf "1\n2\n3\n4\n5" | fzf --prompt="Level ? > ")
RISK=$(printf "1\n2\n3" | fzf --prompt="Risk ? > ")
THREADS=$(printf "1\n5\n10\n20" | fzf --prompt="Threads ? > ")

# Appel GPT-4 pour suggestions de tamper
echo -e "\n\033[1;36m[+] Analyse GPT-4 des paramètres et suggestion de tamper scripts...\033[0m"
gpt_prompt="URL cible : $URL\nMéthode : $METHOD\nParamètres : $(echo "$PARAMS" | paste -sd ",")\n\nPour chaque paramètre, propose des payloads SQLi et les tamper scripts sqlmap les plus pertinents."

tamper_suggestion=$(curl -s https://api.openai.com/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_KEY" \
  -H "Content-Type: application/json" \
  -d @- <<EOF
{
  "model": "gpt-4",
  "messages": [
    {"role": "system", "content": "Tu es un expert en pentest SQLi, XSS et spécialiste sqlmap meme pour une utilisation poussée."},
    {"role": "user", "content": "$gpt_prompt"}
  ],
  "temperature": 0.4
}
EOF
)

echo -e "\n\033[1;33m--- Suggestion GPT-4 ---\033[0m"
echo "$tamper_suggestion" | jq -r '.choices[0].message.content'

# Choix des tampers et options
#TAMPERS=$(echo "$tamper_suggestion" | jq -r '.choices[0].message.content' | grep -oP '[\w_-]+\.py' | uniq | fzf --multi --prompt="Tamper scripts à utiliser : ")
# Extraire les noms suggérés par GPT-4
tamper_names=$(echo "$tamper_suggestion" | jq -r '.choices[0].message.content' | grep -oP '[\w_-]+\.py' | uniq)

# Lister tous les fichiers tamper disponibles localement
tamper_dir="/root/sqlmap/tamper"
available_tampers=$(find "$tamper_dir" -type f -name "*.py" -exec basename {} \;)

# Fusionner et filtrer avec fzf
TAMPERS=$(printf "%s\n%s" "$tamper_names" "$available_tampers" | sort -u | fzf --multi --prompt="Tamper scripts à utiliser : ")
EXTRA=$(printf -- "--batch\n--random-agent\n--drop-set-cookie\n--flush-session\n--dbms=mysql\n--crawl=2\n--forms\n--technique=BEUSTQ\n--no-cast" | fzf --multi --prompt="Options sqlmap supplémentaires : ")

# Construction commande SQLMap
CMD="python3 /root/sqlmap/sqlmap.py -u \"$URL\" --threads=$THREADS --level=$LEVEL --risk=$RISK"
[[ -n "$POSTDATA" ]] && CMD+=" --data=\"$POSTDATA\""
[[ -n "$COOKIES" ]] && CMD+=" --cookie=\"$COOKIES\""
[[ -n "$UA" ]] && CMD+=" --user-agent=\"$UA\""
[[ -n "$REFERER" ]] && CMD+=" --referer=\"$REFERER\""
[[ -n "$TAMPERS" ]] && CMD+=" --tamper=$(echo "$TAMPERS" | paste -sd "," -)"
[[ -n "$EXTRA" ]] && CMD+=" $(echo "$EXTRA" | paste -sd " " -)"

echo -e "\n\033[1;32m[+] Commande SQLMap générée :\033[0m\n$CMD\n"
read -p "Exécuter maintenant ? (y/n) : " EXEC

if [[ "$EXEC" =~ ^[Yy]$ ]]; then
  eval "$CMD" | tee sqlmap_output.txt
fi

# Rapport Markdown
{
  echo "# Rapport SQLMap - $timestamp"
  echo "**URL cible**: $URL"
  echo "**Méthode**: $METHOD"
  echo "**Paramètres détectés**: \`$(echo $PARAMS | paste -sd ", " -)\`"
  echo "**Tamper utilisés**: \`$TAMPERS\`"
  echo "**Options**: \`$EXTRA\`"
  echo -e "\n**Commande exécutée :**\n\`\`\`bash\n$CMD\n\`\`\`"
  echo -e "\n**Sortie partielle :**\n\`\`\`"
  head -n 50 sqlmap_output.txt 2>/dev/null || echo "Pas de sortie sqlmap"
  echo -e "\n...\n\`\`\`"
  echo -e "\n**Analyse GPT-4 :**\n\`\`\`\n$(echo "$tamper_suggestion" | jq -r '.choices[0].message.content')\n\`\`\`"
} > "$report_md"

# Rapport HTML
{
  echo "<html><head><meta charset='utf-8'><title>SQLMap Report</title></head><body style='font-family: monospace; background: #0d0d0d; color: #00ffcc;'>"
  echo "<h1>Rapport SQLMap - $timestamp</h1>"
  echo "<p><b>URL cible:</b> $URL</p>"
  echo "<p><b>Méthode:</b> $METHOD</p>"
  echo "<p><b>Paramètres:</b> $(echo "$PARAMS" | paste -sd ", ")</p>"
  echo "<p><b>Tamper:</b> $TAMPERS</p>"
  echo "<p><b>Options:</b> $EXTRA</p>"
  echo "<h3>Commande exécutée :</h3><pre>$CMD</pre>"
  echo "<h3>Sortie partielle SQLMap :</h3><pre>$(head -n 50 sqlmap_output.txt 2>/dev/null || echo 'Pas de sortie sqlmap')</pre>"
  echo "<h3>Analyse GPT-4 :</h3><pre>$(echo "$tamper_suggestion" | jq -r '.choices[0].message.content')</pre>"
} > "$report_html"

echo -e "\n\033[1;34m[✔] Rapport enregistré :\033[0m"
echo -e "- Markdown : $report_md"
echo -e "- HTML     : $report_html"

# Auto-analyse GPT-4 sortie SQLMap
if [[ -s sqlmap_output.txt ]]; then
  echo -e "\n\033[1;36m[+] Auto-analyse de la sortie SQLMap avec GPT-4...\033[0m"
  sqlmap_preview=$(head -n 150 sqlmap_output.txt)

  auto_analysis=$(curl -s https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_KEY" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "model": "gpt-4",
  "messages": [
    {"role": "system", "content": "Tu es un expert en pentest et tu dois analyser la sortie de sqlmap."},
    {"role": "user", "content": "Voici une sortie partielle de sqlmap:\n\n$sqlmap_preview\n\nDonne un résumé clair des vulnérabilités trouvées et des prochaines étapes potentielles. Conseilles l'utilisateur sur des pistes probables d'exploitation en tenant compte des résultats obtenus avec sqlmap"}
  ],
  "temperature": 0.4
}
EOF
  )

  echo -e "\n\033[1;35m--- Auto-analyse GPT-4 ---\033[0m"
  echo "$auto_analysis" | jq -r '.choices[0].message.content'

  # Ajout au rapport
  {
    echo -e "\n**Auto-analyse GPT-4 :**\n\`\`\`\n$(echo "$auto_analysis" | jq -r '.choices[0].message.content')\n\`\`\`"
  } >> "$report_md"

  {
    echo "<h3>Auto-analyse GPT-4 :</h3><pre>$(echo "$auto_analysis" | jq -r '.choices[0].message.content')</pre>"
    echo "</body></html>"
  } >> "$report_html"

else
  echo -e "\033[1;33m[!] Aucune sortie sqlmap trouvée pour auto-analyse.\033[0m"
fi
