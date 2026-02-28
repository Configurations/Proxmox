
Apres s'être connecté sur l'IHM web

Configurer la clé API Anthropic (sans ça aucun agent ne peut répondre)
Dans le dashboard : Settings → Config ou Agents → ton agent → Auth
Il faut rentrer ton ANTHROPIC_API_KEY.


2. Vérifier que les agents sont bien listés
Agent → Agents — tu devrais voir tes 8 agents. Si la liste est vide c'est que install-agents.sh n'a pas encore tourné dans le bon container.
3. Configurer un canal de communication
Le plus simple pour tester rapidement : Channels → Add channel → Telegram ou Slack.
Sans canal, tu ne peux pas interagir avec les agents depuis l'extérieur.
Dis-moi ce que tu vois dans Agents et Channels — et quelle clé API tu veux configurer en premier (Anthropic obligatoire, Slack/Telegram optionnel pour l'instant).