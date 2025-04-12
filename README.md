# Easy Query

Easy Query è un'applicazione Flutter progettata per consentire agli utenti di formulare richieste in linguaggio naturale, tradurle in query SQL (o altre), eseguirle su un data lake/warehouse (Google Cloud + BigQuery) e restituire risultati arricchiti con analisi descrittive e grafici.

## Funzionalità principali

- **Interfaccia utente intuitiva**: Una web-app Flutter per interagire con il sistema.
- **Agente AI avanzato**: Utilizzo di un modello LLM (Gemini Flash 2.0) per comprendere le richieste in linguaggio naturale e generare query SQL.
- **Integrazione con Google Cloud**:
    - BigQuery come motore di query.
    - Cloud Storage per la gestione dei dati strutturati e non strutturati.
    - Supporto per pipeline di dati in streaming o batch.
- **Analisi e visualizzazione**: Risultati arricchiti con analisi testuali e grafici dinamici.
- **Integrazione di nuove fonti dati**: Processo di ingestion scalabile per dati eterogenei.

## Workflow

1. L'utente inserisce una richiesta in linguaggio naturale tramite l'interfaccia Flutter.
2. L'agente AI elabora la richiesta e genera una query SQL.
3. La query viene eseguita su BigQuery e i risultati vengono raccolti.
4. L'agente AI analizza i risultati e genera una risposta testuale con eventuali grafici.
5. L'utente visualizza i risultati e l'analisi nella web-app.

## Installazione

Per configurare e avviare l'applicazione, segui questi passaggi:

1. **Clona il repository**:
     ```bash
     git clone https://github.com/lukebo01/easy_query.git
     cd easy_query
     ```

2. **Installa le dipendenze**:
     ```bash
     flutter pub get
     ```

3. **Esegui l'app**:
     ```bash
     flutter run
     ```

## Requisiti

- **Flutter**: Assicurati di avere Flutter installato. Segui la guida ufficiale [qui](https://docs.flutter.dev/get-started/install).
- **Google Cloud**: Configura un progetto Google Cloud con BigQuery e Cloud Storage abilitati.

## Architettura

- **Frontend**: Flutter per l'interfaccia utente.
- **Backend**: Google Cloud per l'elaborazione e la gestione dei dati.
- **AI Agent**: Gemini Flash 2.0 per la comprensione del linguaggio naturale e la generazione di query.

## Contributi

Contribuisci al progetto aprendo una pull request o segnalando problemi nella sezione [Issues](https://github.com/tuo-utente/easy_query/issues).

## Licenza

Questo progetto è distribuito sotto la licenza MIT. Consulta il file [LICENSE](LICENSE) per maggiori dettagli.
