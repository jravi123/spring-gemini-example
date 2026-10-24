/**
 * Frontend controller for the Personal Travel Agent application.
 */

const travelForm = document.getElementById('travelForm');
const destinationInput = document.getElementById('destination');
const datesInput = document.getElementById('dates');
const interestsInput = document.getElementById('interests');
const budgetInput = document.getElementById('budget');
const generateBtn = document.getElementById('generateBtn');
const generateBtnSpinner = document.getElementById('generateBtnSpinner');
const generateBtnText = document.getElementById('generateBtnText');

const suggestionsDisplay = document.getElementById('suggestionsDisplay');
const suggestionsContent = document.getElementById('suggestionsContent');
const errorDisplay = document.getElementById('errorDisplay');
const errorMessage = document.getElementById('errorMessage');

const chatContainer = document.getElementById('chatContainer');
const chatForm = document.getElementById('chatForm');
const chatInput = document.getElementById('chatInput');
const sendChatBtn = document.getElementById('sendChatBtn');
const sendChatSpinner = document.getElementById('sendChatSpinner');
const sendChatIcon = document.getElementById('sendChatIcon');
const chatHistoryDisplay = document.getElementById('chatHistoryDisplay');

/**
 * Structured multi-turn conversation history [{ role: 'USER' | 'ASSISTANT', content: string }]
 */
let conversationHistory = [];

/**
 * Toggles the loading state of the primary plan generation button.
 * @param {boolean} isLoading
 */
function setGenerateLoading(isLoading) {
    generateBtn.disabled = isLoading;
    generateBtn.setAttribute('aria-busy', String(isLoading));
    generateBtn.classList.toggle('opacity-60', isLoading);
    generateBtn.classList.toggle('cursor-not-allowed', isLoading);
    generateBtnSpinner.classList.toggle('hidden', !isLoading);
    generateBtnText.textContent = isLoading ? 'Generating...' : 'Get Travel Suggestions';
}

/**
 * Toggles the loading state of the follow-up chat submit button.
 * @param {boolean} isLoading
 */
function setChatLoading(isLoading) {
    sendChatBtn.disabled = isLoading;
    chatInput.disabled = isLoading;
    sendChatBtn.setAttribute('aria-busy', String(isLoading));
    sendChatBtn.classList.toggle('opacity-60', isLoading);
    sendChatBtn.classList.toggle('cursor-not-allowed', isLoading);
    sendChatSpinner.classList.toggle('hidden', !isLoading);
    sendChatIcon.classList.toggle('hidden', isLoading);
}

/**
 * Displays or clears an error banner.
 * @param {string|null} message
 */
function displayError(message) {
    if (message) {
        errorMessage.textContent = message;
        errorDisplay.classList.remove('hidden');
    } else {
        errorMessage.textContent = '';
        errorDisplay.classList.add('hidden');
    }
}

/**
 * Safely appends a message to the chat history display without XSS vulnerabilities.
 * User messages are rendered strictly via textContent; AI responses use server-escaped HTML.
 *
 * @param {'USER'|'ASSISTANT'} role
 * @param {string} content - Plain text for USER, sanitized HTML for ASSISTANT
 */
function appendMessageToChat(role, content) {
    const wrapper = document.createElement('div');
    wrapper.className = 'mb-3 last:mb-0 p-3 rounded-lg ' +
        (role === 'USER' ? 'bg-blue-50 border border-blue-100' : 'bg-white border border-gray-200');

    const senderLabel = document.createElement('strong');
    senderLabel.className = role === 'USER' ? 'text-blue-700 block mb-1' : 'text-emerald-700 block mb-1';
    senderLabel.textContent = role === 'USER' ? 'You:' : 'Travel Agent:';

    const body = document.createElement('div');
    if (role === 'USER') {
        body.className = 'text-gray-800 whitespace-pre-wrap';
        body.textContent = content;
    } else {
        body.className = 'markdown-body text-gray-800 leading-relaxed';
        body.innerHTML = content;
    }

    wrapper.appendChild(senderLabel);
    wrapper.appendChild(body);
    chatHistoryDisplay.appendChild(wrapper);
    chatHistoryDisplay.scrollTop = chatHistoryDisplay.scrollHeight;
}

/**
 * Extracts a human-readable error message from a failed fetch Response.
 * @param {Response} response
 * @returns {Promise<string>}
 */
async function extractErrorMessage(response) {
    try {
        const contentType = response.headers.get('content-type') || '';
        if (contentType.includes('application/problem+json') || contentType.includes('application/json')) {
            const problem = await response.json();
            return problem.detail || problem.title || `Status ${response.status}`;
        }
        const text = await response.text();
        return text || `Status ${response.status}`;
    } catch {
        return `Status ${response.status}`;
    }
}

/**
 * Handles initial travel plan generation form submission.
 */
travelForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    setGenerateLoading(true);
    displayError(null);

    const payload = {
        destination: destinationInput.value.trim(),
        dates: datesInput.value.trim(),
        interests: interestsInput.value.trim(),
        budget: budgetInput.value.trim()
    };

    try {
        const response = await fetch('/ai/plan', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errDetail = await extractErrorMessage(response);
            throw new Error(errDetail);
        }

        const data = await response.json();

        // Reset multi-turn conversation history with proper role boundaries
        conversationHistory = [
            { role: 'USER', content: data.userPrompt },
            { role: 'ASSISTANT', content: data.markdown }
        ];

        suggestionsContent.innerHTML = data.html;
        suggestionsDisplay.classList.remove('hidden');
        chatHistoryDisplay.innerHTML = '';
        chatContainer.classList.remove('hidden');
    } catch (err) {
        console.error('Travel plan generation error:', err);
        displayError(`Failed to get travel suggestions: ${err.message}`);
    } finally {
        setGenerateLoading(false);
    }
});

/**
 * Handles follow-up chat form submission.
 */
chatForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const userText = chatInput.value.trim();
    if (!userText) {
        return;
    }

    chatInput.value = '';
    displayError(null);
    appendMessageToChat('USER', userText);
    conversationHistory.push({ role: 'USER', content: userText });

    setChatLoading(true);

    try {
        const response = await fetch('/ai/chat', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ messages: conversationHistory })
        });

        if (!response.ok) {
            const errDetail = await extractErrorMessage(response);
            throw new Error(errDetail);
        }

        const data = await response.json();
        conversationHistory.push({ role: 'ASSISTANT', content: data.markdown });
        appendMessageToChat('ASSISTANT', data.html);
    } catch (err) {
        console.error('Chat error:', err);
        // Remove the failed turn from history so the user can retry cleanly
        conversationHistory.pop();
        displayError(`Failed to send message: ${err.message}`);
    } finally {
        setChatLoading(false);
        chatInput.focus();
    }
});

/**
 * IME-safe Enter-to-submit handler for the chat input.
 */
chatInput.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
        event.preventDefault();
        if (event.isComposing || event.keyCode === 229) {
            return;
        }
        chatForm.requestSubmit();
    }
});
