# Architecture

## High-level architecture

```mermaid
flowchart TB
    subgraph UserZone[User experience]
      USER[Authenticated user]
      UI[Web interface]
    end

    subgraph AppZone[Application boundary]
      API[FastAPI service]
      CFG[Configuration]
      RET[Retrieval service]
      GEN[Generation service]
      EVAL[Evaluation service]
      TEL[Telemetry]
    end

    subgraph AzureZone[Azure services]
      ENTRA[Microsoft Entra ID]
      SEARCH[Azure AI Search]
      AOAI[Azure OpenAI]
      KV[Azure Key Vault]
      APPINS[Application Insights]
      STORAGE[Approved document storage]
    end

    USER --> UI --> API
    API --> ENTRA
    API --> RET --> SEARCH --> STORAGE
    API --> GEN --> AOAI
    API --> EVAL
    API --> TEL --> APPINS
    CFG --> KV

    classDef trust fill:#eef,stroke:#445;
    class UserZone,AppZone,AzureZone trust;
```

## Legend

| Symbol | Meaning |
|---|---|
| Solid arrow | Runtime request or data flow |
| Dotted relationship | Configuration, secret, or telemetry relationship |
| Boundary | Security or responsibility zone |

## Core rule

The model must not answer from unsupported knowledge when the solution is configured for grounded enterprise responses. When retrieval produces insufficient evidence, the application must return a transparent “not found in approved sources” response.
