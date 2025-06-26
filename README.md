# Spring Boot Gemini Demo

This is a demo project for using Spring Boot, along with Spring AI that uses Google's Gemini Pro model.

## Prerequisites

* Java 21
* Maven
* Google Cloud SDK

### Installing the Google Cloud SDK

If you don't have the Google Cloud SDK installed, follow these steps:

1.  **Download the Google Cloud SDK:**
    *   Go to the official Google Cloud SDK documentation page to download the appropriate installer for your operating system (Windows, macOS, or Linux): [https://cloud.google.com/sdk/docs/install](https://cloud.google.com/sdk/docs/install)

2.  **Install the SDK:**
    *   **For Windows:** Run the installer you downloaded. It's a graphical installer that will guide you through the process.
    *   **For macOS and Linux:**
        *   Extract the downloaded archive file. It's recommended to extract it to your home directory.
        *   Run the installation script from the extracted directory:
            ```bash
            ./google-cloud-sdk/install.sh
            ```
        *   The script will prompt you to update your system's PATH and enable shell command completion. It's recommended to agree to this to make the `gcloud` command available in your terminal.

3.  **Initialize the SDK:**
    *   After the installation is complete, you need to initialize the SDK to connect it to your Google Cloud account.
    *   Open a new terminal window (or restart your current one for the changes to take effect).
    *   Run the `gcloud init` command:
        ```bash
        gcloud init
        ```
    *   This command will walk you through:
        *   Logging into your Google Cloud account in a web browser.
        *   Selecting a Google Cloud project to work with.
        *   Configuring a default region and zone.

4.  **Verify the Installation:**
    *   To confirm that the SDK has been installed and configured correctly, you can run a simple `gcloud` command, such as listing your projects or active configuration.
        ```bash
        gcloud projects list
        ```

## Configuration

1.  **`pom.xml`**: The `pom.xml` is configured to use the `spring-ai-starter-model-vertex-ai-gemini` dependency. The App Engine Maven plugin is also configured for deployment.

2.  **`src/main/resources/application.properties`**: This file contains the configuration for the Vertex AI Gemini model. You will need to replace the `spring.ai.vertex.ai.gemini.project-id` with your own Google Cloud project ID.

3.  **`src/main/appengine/app.yaml`**: This file configures the App Engine deployment. It is set to use the `java21` runtime.

## Running the Application

To run the application locally, use the following command:

```bash
./mvnw spring-boot:run
```

## Deploying to App Engine

To deploy the application to App Engine, use the following command:

```bash
gcloud app deploy
```

Before deploying, make sure you have authenticated with the Google Cloud SDK and have set the correct project.


A version of deployed application on App Engine can be accessed [here](https://mbcc-test.appspot.com/)

## References

* Spring AI: https://docs.spring.io/spring-ai/reference/index.html


Google Cloud credits are provided for this project #AISprint

