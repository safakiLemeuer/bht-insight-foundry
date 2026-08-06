# Data Flow

```mermaid
sequenceDiagram
    actor User
    participant UI as Web interface
    participant API as BHT Insight API
    participant Entra as Microsoft Entra ID
    participant Search as Azure AI Search
    participant OpenAI as Azure OpenAI
    participant Monitor as Application Insights

    User->>UI: Submit question
    UI->>API: Question and identity token
    API->>Entra: Validate identity and claims
    Entra-->>API: Validated user context
    API->>Search: Retrieve approved passages
    Search-->>API: Ranked passages and source metadata
    API->>OpenAI: Prompt plus approved evidence
    OpenAI-->>API: Grounded response
    API->>Monitor: Safe operational telemetry
    API-->>UI: Answer, citations, and confidence metadata
    UI-->>User: Display response
```

## Data handling rules

- Do not send documents to the model unless retrieval selected them for the current request.
- Do not expose content the authenticated user is not authorized to access.
- Do not place secrets in prompts, logs, or source metadata.
- Return citations to approved sources.
