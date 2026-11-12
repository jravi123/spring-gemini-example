# Spring Boot Gemini Demo

This is a full-stack demo project built with **Spring Boot**, **Spring AI** (Google Vertex AI Gemini), and **Spring Data Cloud Datastore**, deployed as a serverless container on **Google Cloud Run**.

> **Deployment Architecture Note:** This project deploys to **Google Cloud Run** (using `Dockerfile`, Cloud Build, and `run.sh`) rather than Google App Engine. Do not use `mvn appengine:deploy` or `app.yaml` — use `./run.sh` to build and deploy to Cloud Run.

---

## Option 1: Using Google Cloud Shell (Recommended Quickstart)

Google Cloud Shell already comes pre-installed with **Java 21**, **Maven**, **Git**, and the **Google Cloud SDK (`gcloud`)**.

### 1. Clone the Repository & Enter the Project Folder

Open [Google Cloud Shell](https://shell.cloud.google.com/) and run:

```bash
git clone https://github.com/jravi123/spring-gemini-example.git
cd spring-gemini-example
chmod +x run.sh mvnw
```

### 2A. Enable APIs & Run Locally in Cloud Shell

If you want to run the server inside Cloud Shell and preview it in your browser:

```bash
# 1. List your GCP projects, pick a number [1-N], sync application.properties, and enable APIs:
./run.sh --apis-only

# 2. Start the local Spring Boot server on port 8080:
./mvnw spring-boot:run
```

Then click the **Web Preview** button in the top-right corner of Cloud Shell and select **Preview on port 8080** (visit `/` for the Travel Planner and `/user.html` for Create User).

### 2B. Or Build & Deploy to Google Cloud Run

To run tests, build the container image in Cloud Build, and deploy to a public Cloud Run URL in one step:

```bash
# Prompts you to pick your target GCP project by number [1-N], then builds & deploys:
./run.sh
```

---

## Option 2: Using Your Local Computer

> **Note for Windows Users:** Because `run.sh` is a Bash script that uses Linux commands, please open **Git Bash** (included with [Git for Windows](https://gitforwindows.org/)) or **WSL (Windows Subsystem for Linux)** to run the commands below. If using Windows PowerShell or Command Prompt to start the server after enabling APIs, use `.\mvnw.cmd spring-boot:run` instead of `./mvnw spring-boot:run`.

### 1. Prerequisites

* **Java 21**
* **Git** (on Windows, includes **Git Bash**)
* **Google Cloud SDK (`gcloud`)**

#### Installing & Authenticating the Google Cloud SDK

1.  **Download & Install:** Follow the official installer for your OS (Windows, macOS, or Linux) at [https://cloud.google.com/sdk/docs/install](https://cloud.google.com/sdk/docs/install).
    *   On macOS/Linux (archive install):
        ```bash
        ./google-cloud-sdk/install.sh
        ```
2.  **Initialize & Log In:** Open a new terminal (**Git Bash** / **WSL** on Windows, or Terminal on macOS/Linux) and authenticate both the CLI and Application Default Credentials (used by Spring Boot to call Vertex AI and Cloud Datastore locally):
    ```bash
    gcloud init
    gcloud auth application-default login
    gcloud projects list
    ```

### 2. Clone the Repository & Enter the Project Folder

In your terminal (or **Git Bash** on Windows), run:

```bash
git clone https://github.com/jravi123/spring-gemini-example.git
cd spring-gemini-example
chmod +x run.sh mvnw
```

### 3A. Enable APIs & Start the Local Instance

Before running locally for the first time, use `./run.sh --apis-only` to enable the required GCP APIs (Vertex AI, Cloud Datastore, Cloud Run, Artifact Registry, Cloud Build, IAM, and Logging) and automatically write your selected project ID into `src/main/resources/application.properties`:

```bash
# 1. Pick your GCP project by number [1-N] and enable required APIs:
./run.sh --apis-only

# 2. Start the local Spring Boot server (macOS / Linux / Git Bash):
./mvnw spring-boot:run

# (Or if using Windows PowerShell / CMD):
.\mvnw.cmd spring-boot:run
```

> **Smart Caching Note:** `run.sh` remembers which project has already had its APIs enabled. If you already ran `./run.sh --apis-only`, subsequent runs of `./run.sh` or `./run.sh --apis-only` for the same project will automatically skip the API enablement step (pass `--force` if you ever want to re-verify).

Open your browser to:
* `http://localhost:8080` — Personal Travel Agent UI
* `http://localhost:8080/user.html` — Create User (Cloud Datastore) UI

*(With `spring-boot-devtools` included, compiled changes in `target/classes` hot-reload automatically).*

### 3B. Or Build & Deploy to Google Cloud Run

```bash
# Interactive project selection [1-N] + full build, test, scan, and Cloud Run deploy
# (Automatically skips API enablement if already enabled for the selected project):
./run.sh

# Fast build & deploy (skip JUnit tests and SpotBugs scan):
./run.sh --skip-tests --skip-scans

# Force a full rebuild, API re-verification, and redeploy (bypassing cache):
./run.sh --force
```

---

## `run.sh` Options Reference

| Option | Description |
|---|---|
| `--project <id>`, `-p <id>` | Target a specific GCP Project ID directly (skips the interactive numbered prompt and updates `application.properties`). |
| `--billing-account <id>`, `-b <id>` | Link a specific Cloud Billing Account ID if billing is disabled on the target project (otherwise auto-detected/prompted). |
| `--apis-only` | Only verify billing and enable required Google Cloud APIs for the selected project, then exit. |
| `--skip-tests` | Skip running JUnit unit tests during the Maven build. |
| `--skip-scans` | Skip running SpotBugs SAST code analysis. |
| `--force`, `--rebuild`, `-f` | Bypass smart caching and force a complete rebuild and redeployment. |
| `--help`, `-h` | Display usage and options help. |

## Project Configuration Files

1.  **`pom.xml`**: Configured with `spring-ai-starter-model-google-genai` (Vertex AI Gemini) and `spring-cloud-gcp-starter-data-datastore` (Google Cloud Datastore).
2.  **`src/main/resources/application.properties`**: Contains the configuration for the Google Cloud project ID and Vertex AI Gemini model (`gemini-3.8-flash`). Running `./run.sh --apis-only` or `./run.sh` automatically updates the project ID in this file.
3.  **`Dockerfile` & `run.sh`**: Used to containerize and deploy the application to **Google Cloud Run** (replacing legacy App Engine `app.yaml` deployments).

## How AI & Cloud Datastore Storage Work in This App

* **AI Travel Planner (`/` — `index.html` $\rightarrow$ `POST /ai/plan` & `POST /ai/chat`):**
  * Calls **Vertex AI Gemini** (`BackendService.generateTravelPlan` and `BackendService.chat`) to generate travel itineraries and answer follow-up questions.
  * **Does NOT store anything in Cloud Datastore.** Multi-turn conversation history (`conversationHistory`) is held in browser memory in `script.js` and sent with each chat request.
* **Create User Page (`/user.html` $\rightarrow$ `POST /ai/user`):**
  * Stores data in **Google Cloud Datastore**. Submitting the Create User form sends a JSON payload (`firstName`, `lastName`) to `AiController.createUser`, which calls `BackendService.saveUser` $\rightarrow$ `UserRepository.save(user)` to persist a `User` entity (`id`, `firstName`, `lastName`) into the `User` kind in Cloud Datastore.

## References

* Spring AI: https://docs.spring.io/spring-ai/reference/index.html

Google Cloud credits are provided for this project #AISprint, #AISpringH2

