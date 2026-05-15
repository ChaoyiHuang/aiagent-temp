#!/bin/bash
# OpenClaw Discord Deployment Script
# This script helps you deploy an OpenClaw instance connected to Discord
#
# Prerequisites:
# - Kind cluster running (from E2E tests)
# - Discord Bot Token (from Discord Developer Portal)
# - Discord User IDs (whitelist)
# - DeepSeek API Key (or other LLM provider)
#
# Environment Variables (required for non-interactive deployment):
#   DISCORD_BOT_TOKEN    - Discord bot token from Developer Portal
#   DISCORD_USER_IDS     - Comma-separated list of Discord user IDs (whitelist)
#   DEEPSEEK_API_KEY     - DeepSeek API key for LLM
#   DISCORD_GUILD_ID     - (optional) Discord server ID to restrict bot
#   DISCORD_COMMAND_PREFIX - (optional) Bot command prefix, default: !
#
# Usage:
#   # With environment variables (non-interactive)
#   export DISCORD_BOT_TOKEN="your-bot-token"
#   export DISCORD_USER_IDS="123456789,987654321"
#   export DEEPSEEK_API_KEY="your-api-key"
#   ./deploy-openclaw-discord.sh
#
#   # Without environment variables (interactive - prompts for input)
#   ./deploy-openclaw-discord.sh
#
#   ./deploy-openclaw-discord.sh --help       # Show help
#   ./deploy-openclaw-discord.sh --status     # Check deployment status
#   ./deploy-openclaw-discord.sh --cleanup    # Remove Discord deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="aiagent-system"

echo "=================================================="
echo "OpenClaw Discord Bot Deployment"
echo "=================================================="

# ============================================================
# Helper Functions
# ============================================================

show_help() {
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (none)          Deploy with environment variables or interactive input"
    echo "  --help          Show this help message"
    echo "  --status        Check Discord deployment status"
    echo "  --cleanup       Remove Discord deployment"
    echo "  --show-config   Show generated config without deploying"
    echo ""
    echo "Environment Variables:"
    echo "  DISCORD_BOT_TOKEN     (required) Discord bot token"
    echo "  DISCORD_USER_IDS      (required) Comma-separated user IDs whitelist"
    echo "  DEEPSEEK_API_KEY      (required) DeepSeek API key"
    echo "  DISCORD_GUILD_ID      (optional)  Server ID to restrict bot"
    echo "  DISCORD_COMMAND_PREFIX (optional) Command prefix, default: !"
    echo ""
    echo "Example (non-interactive):"
    echo "  export DISCORD_BOT_TOKEN='MTk4NjIyMzQ1Njc4OTk...'"
    echo "  export DISCORD_USER_IDS='123456789012345678,987654321098765432'"
    echo "  export DEEPSEEK_API_KEY='sk-xxx...'"
    echo "  ./deploy-openclaw-discord.sh"
    echo ""
    echo "How to get Discord credentials:"
    echo "  1. Discord Bot Token:"
    echo "     - Go to https://discord.com/developers/applications"
    echo "     - Create/select application"
    echo "     - Bot section > Copy Token"
    echo "     - Enable 'Message Content Intent'"
    echo ""
    echo "  2. Discord User IDs:"
    echo "     - Enable Developer Mode: User Settings > Advanced > Developer Mode"
    echo "     - Right-click user > Copy User ID"
    echo "     - Multiple IDs: comma-separated (e.g., 123456,789012)"
    echo ""
    echo "  3. DeepSeek API Key:"
    echo "     - Go to https://platform.deepseek.com/api_keys"
    echo "     - Create new API key"
    echo ""
    exit 0
}

check_cluster() {
    echo ""
    echo ">>> Checking Kind cluster status..."

    if ! kind get clusters 2>/dev/null | grep -q "aiagent-test"; then
        echo "    ❌ ERROR: Kind cluster 'aiagent-test' not found"
        echo "    Please run E2E tests first: ./run-e2e-test.sh"
        exit 1
    fi

    if ! kubectl get ns aiagent-system 2>/dev/null | grep -q "aiagent-system"; then
        echo "    ❌ ERROR: Namespace 'aiagent-system' not found"
        echo "    Please run E2E tests first: ./run-e2e-test.sh"
        exit 1
    fi

    # Check manager is running
    MANAGER_STATUS=$(kubectl get deployment aiagent-manager -n ${NS} -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
    if [ "$MANAGER_STATUS" != "1" ]; then
        echo "    ⚠ WARNING: AIAgent Manager not ready"
        echo "    Deploying manager..."
        kubectl apply -f "${SCRIPT_DIR}/manifests/manager-deployment.yaml"
        sleep 10
    fi

    echo "    ✓ Cluster ready"
}

show_status() {
    echo ""
    echo ">>> Discord Deployment Status"
    echo "=================================================="

    echo ""
    echo ">>> AgentRuntime:"
    kubectl get agentruntime discord-runtime -n ${NS} 2>/dev/null || echo "    Not deployed"

    echo ""
    echo ">>> AIAgent:"
    kubectl get aiagent discord-bot-1 -n ${NS} 2>/dev/null || echo "    Not deployed"

    echo ""
    echo ">>> Pods:"
    kubectl get pods -n ${NS} -l runtime=discord-runtime 2>/dev/null || echo "    No pods running"

    echo ""
    echo ">>> Secrets:"
    kubectl get secret discord-bot-token -n ${NS} 2>/dev/null || echo "    discord-bot-token: Not created"
    kubectl get secret deepseek-api-key -n ${NS} 2>/dev/null || echo "    deepseek-api-key: Not created"

    echo ""
    echo ">>> Harness CRDs:"
    kubectl get harness discord-deepseek-model -n ${NS} 2>/dev/null || echo "    discord-deepseek-model: Not created"
    kubectl get harness discord-skills -n ${NS} 2>/dev/null || echo "    discord-skills: Not created"
    kubectl get harness discord-memory -n ${NS} 2>/dev/null || echo "    discord-memory: Not created"

    # Check agentConfig
    echo ""
    echo ">>> AgentConfig Channels:"
    DISCORD_ENABLED=$(kubectl get aiagent discord-bot-1 -n ${NS} -o jsonpath='{.spec.agentConfig.channels.discord.enabled}' 2>/dev/null)
    if [ "$DISCORD_ENABLED" == "true" ]; then
        echo "    Discord enabled: true"
        ALLOWED_USERS=$(kubectl get aiagent discord-bot-1 -n ${NS} -o jsonpath='{.spec.agentConfig.channels.discord.allowedUsers}' 2>/dev/null)
        echo "    Allowed users: ${ALLOWED_USERS}"
    else
        echo "    Discord not configured"
    fi

    echo ""
    echo "=================================================="
}

cleanup() {
    echo ""
    echo ">>> Cleaning up Discord deployment..."

    kubectl delete aiagent discord-bot-1 -n ${NS} 2>/dev/null || true
    kubectl delete agentruntime discord-runtime -n ${NS} 2>/dev/null || true
    kubectl delete harness discord-deepseek-model -n ${NS} 2>/dev/null || true
    kubectl delete harness discord-skills -n ${NS} 2>/dev/null || true
    kubectl delete harness discord-memory -n ${NS} 2>/dev/null || true
    kubectl delete secret discord-bot-token -n ${NS} 2>/dev/null || true
    kubectl delete secret deepseek-api-key -n ${NS} 2>/dev/null || true

    # Wait for pods to terminate
    echo "    Waiting for pods to terminate..."
    sleep 5

    echo "    ✓ Cleanup complete"
}

# ============================================================
# Credential Collection (Environment Variables or Interactive)
# ============================================================

collect_credentials() {
    echo ""
    echo "=================================================="
    echo "Collecting Credentials"
    echo "=================================================="

    # Check if environment variables are set
    if [ -n "$DISCORD_BOT_TOKEN" ] && [ -n "$DISCORD_USER_IDS" ] && [ -n "$DEEPSEEK_API_KEY" ]; then
        echo ""
        echo ">>> Using environment variables (non-interactive mode)"
        DISCORD_TOKEN="$DISCORD_BOT_TOKEN"
        echo "    ✓ DISCORD_BOT_TOKEN: set"

        echo "    ✓ DISCORD_USER_IDS: ${DISCORD_USER_IDS}"

        DEEPSEEK_KEY="$DEEPSEEK_API_KEY"
        echo "    ✓ DEEPSEEK_API_KEY: set"

        # Optional env vars
        if [ -n "$DISCORD_GUILD_ID" ]; then
            DISCORD_GUILD_YAML="        allowedGuilds:\n        - \"${DISCORD_GUILD_ID}\""
            echo "    ✓ DISCORD_GUILD_ID: ${DISCORD_GUILD_ID}"
        else
            DISCORD_GUILD_YAML=""
        fi

        COMMAND_PREFIX="${DISCORD_COMMAND_PREFIX:-!}"
        echo "    ✓ DISCORD_COMMAND_PREFIX: ${COMMAND_PREFIX}"

        return
    fi

    # Interactive mode - prompt for missing credentials
    echo ""
    echo ">>> Environment variables not set, entering interactive mode"
    echo "    (Set DISCORD_BOT_TOKEN, DISCORD_USER_IDS, DEEPSEEK_API_KEY for non-interactive)"
    echo ""

    # Discord Bot Token
    if [ -z "$DISCORD_BOT_TOKEN" ]; then
        echo ">>> Discord Bot Token"
        echo "    How to get:"
        echo "    1. https://discord.com/developers/applications"
        echo "    2. Create/select application"
        echo "    3. Bot section > Copy Token"
        echo ""
        read -p "    Enter Discord Bot Token: " -s DISCORD_TOKEN
        echo ""

        if [ -z "$DISCORD_TOKEN" ]; then
            echo "    ❌ ERROR: Discord Bot Token is required"
            echo "    Set environment variable: export DISCORD_BOT_TOKEN='your-token'"
            exit 1
        fi
        echo "    ✓ Token received"
    else
        DISCORD_TOKEN="$DISCORD_BOT_TOKEN"
        echo "    ✓ DISCORD_BOT_TOKEN from environment"
    fi

    # Discord User IDs
    if [ -z "$DISCORD_USER_IDS" ]; then
        echo ""
        echo ">>> Discord User IDs (Whitelist)"
        echo "    How to get:"
        echo "    1. Discord: User Settings > Advanced > Developer Mode"
        echo "    2. Right-click user > Copy User ID"
        echo "    Enter multiple IDs separated by comma (e.g., 123456789,987654321)"
        echo "    Leave empty to allow all users (not recommended)"
        echo ""
        read -p "    Enter Discord User IDs: " DISCORD_USER_IDS

        if [ -n "$DISCORD_USER_IDS" ]; then
            echo "    ✓ User IDs configured: ${DISCORD_USER_IDS}"
        else
            echo "    ⚠ No whitelist - bot will respond to all users"
        fi
    else
        echo "    ✓ DISCORD_USER_IDS from environment: ${DISCORD_USER_IDS}"
    fi

    # DeepSeek API Key
    if [ -z "$DEEPSEEK_API_KEY" ]; then
        echo ""
        echo ">>> DeepSeek API Key"
        echo "    How to get:"
        echo "    1. https://platform.deepseek.com/api_keys"
        echo "    2. Create new API key"
        echo ""
        read -p "    Enter DeepSeek API Key: " -s DEEPSEEK_KEY
        echo ""

        if [ -z "$DEEPSEEK_KEY" ]; then
            echo "    ❌ ERROR: DeepSeek API Key is required"
            echo "    Set environment variable: export DEEPSEEK_API_KEY='your-key'"
            exit 1
        fi
        echo "    ✓ API Key received"
    else
        DEEPSEEK_KEY="$DEEPSEEK_API_KEY"
        echo "    ✓ DEEPSEEK_API_KEY from environment"
    fi

    # Optional: Guild ID (interactive if not set)
    if [ -z "$DISCORD_GUILD_ID" ]; then
        echo ""
        echo ">>> Optional: Discord Server (Guild) ID"
        echo "    Restrict bot to specific server"
        echo "    How to get: Right-click server icon > Copy Server ID"
        echo "    Leave empty to allow all servers"
        echo ""
        read -p "    Enter Discord Guild ID (optional): " DISCORD_GUILD_ID_INPUT

        if [ -n "$DISCORD_GUILD_ID_INPUT" ]; then
            DISCORD_GUILD_YAML="        allowedGuilds:\n        - \"${DISCORD_GUILD_ID_INPUT}\""
            echo "    ✓ Guild ID configured"
        else
            DISCORD_GUILD_YAML=""
        fi
    else
        DISCORD_GUILD_YAML="        allowedGuilds:\n        - \"${DISCORD_GUILD_ID}\""
        echo "    ✓ DISCORD_GUILD_ID from environment"
    fi

    # Command Prefix
    if [ -z "$DISCORD_COMMAND_PREFIX" ]; then
        echo ""
        echo ">>> Optional: Bot Command Prefix"
        echo "    Example: ! (for !help, !chat)"
        echo "    Default: !"
        echo ""
        read -p "    Enter command prefix [!]: " COMMAND_PREFIX_INPUT
        COMMAND_PREFIX="${COMMAND_PREFIX_INPUT:-!}"
    else
        COMMAND_PREFIX="$DISCORD_COMMAND_PREFIX"
    fi
    echo "    ✓ Command prefix: ${COMMAND_PREFIX}"
}

generate_config() {
    echo ""
    echo ">>> Generating configuration files..."

    # Generate temporary config files with actual values
    TEMP_DIR="/tmp/discord-deploy-$(date +%s)"
    mkdir -p "$TEMP_DIR"

    # Generate Secrets (values from environment variables)
    cat > "${TEMP_DIR}/secrets.yaml" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  namespace: aiagent-system
  name: discord-bot-token
type: Opaque
stringData:
  token: "${DISCORD_TOKEN}"

---
apiVersion: v1
kind: Secret
metadata:
  namespace: aiagent-system
  name: deepseek-api-key
type: Opaque
stringData:
  api-key: "${DEEPSEEK_KEY}"
EOF

    # Generate Harness
    cat > "${TEMP_DIR}/harness.yaml" <<EOF
---
apiVersion: agent.ai/v1
kind: Harness
metadata:
  namespace: aiagent-system
  name: discord-deepseek-model
spec:
  type: model
  model:
    provider: deepseek
    endpoint: https://api.deepseek.com/v1
    authSecretRef: deepseek-api-key
    defaultModel: deepseek-chat
    models:
    - name: deepseek-chat
      allowed: true
      contextWindow: 164000
    - name: deepseek-coder
      allowed: true
      contextWindow: 164000

---
apiVersion: agent.ai/v1
kind: Harness
metadata:
  namespace: aiagent-system
  name: discord-skills
spec:
  type: skills
  skills:
    hubType: builtin
    skills:
    - name: chat
      version: "1.0"
      allowed: true
    - name: search
      version: "1.0"
      allowed: true

---
apiVersion: agent.ai/v1
kind: Harness
metadata:
  namespace: aiagent-system
  name: discord-memory
spec:
  type: memory
  memory:
    type: inmemory
    ttl: 7200
EOF

    # Generate AgentRuntime
    cat > "${TEMP_DIR}/runtime.yaml" <<EOF
---
apiVersion: agent.ai/v1
kind: AgentRuntime
metadata:
  namespace: aiagent-system
  name: discord-runtime
spec:
  processMode: isolated
  agentHandler:
    image: aiagent/openclaw-handler:test
    env:
    - name: BASE_GATEWAY_PORT
      value: "18800"
    - name: WORK_DIR
      value: "/shared/workdir"
    - name: CONFIG_DIR
      value: "/shared/config"
  agentFramework:
    image: aiagent/openclaw-framework:test
    type: openclaw
  harness:
  - name: discord-deepseek-model
    namespace: aiagent-system
  - name: discord-skills
    namespace: aiagent-system
  - name: discord-memory
    namespace: aiagent-system
  replicas: 1
EOF

    # Generate AIAgent with Discord config using tokenSecretRef (standard K8s Secret approach)
    # OpenClaw v2026.5.7 config schema:
    # - models.mergeModels: true -> Handler adds models.mode: "merge" to OpenClaw config
    # - channels.discord: enabled, tokenSecretRef (Config Daemon resolves to actual token)
    # - agents.list[]: id, name, skills
    # Note: Models configuration comes from Harness CRD (discord-deepseek-model)

    cat > "${TEMP_DIR}/agent.yaml" <<EOF
---
apiVersion: agent.ai/v1
kind: AIAgent
metadata:
  namespace: aiagent-system
  name: discord-bot-1
  labels:
    runtime: discord-runtime
spec:
  description: "Discord Bot powered by DeepSeek"
  runtimeRef:
    type: openclaw
    name: discord-runtime
  agentConfig:
    gateway:
      port: 18800
      bind: "loopback"
      auth:
        mode: "none"
    models:
      mergeModels: true
    channels:
      discord:
        enabled: true
        tokenSecretRef: discord-bot-token
        dmPolicy: "all"
        mentionRequired: false
    agents:
      list:
      - id: "discord-assistant"
        name: "Discord Assistant"
        skills: ["chat", "search"]
EOF

    echo "    ✓ Configuration files generated in ${TEMP_DIR}"
}

deploy() {
    echo ""
    echo ">>> Deploying Discord OpenClaw instance..."

    # Apply Secrets first
    echo "    Applying secrets..."
    kubectl apply -f "${TEMP_DIR}/secrets.yaml"

    # Apply Harness
    echo "    Applying harness CRDs..."
    kubectl apply -f "${TEMP_DIR}/harness.yaml"

    # Apply AgentRuntime
    echo "    Applying agentruntime..."
    kubectl apply -f "${TEMP_DIR}/runtime.yaml"

    # Apply AIAgent
    echo "    Applying aiagent..."
    kubectl apply -f "${TEMP_DIR}/agent.yaml"

    echo ""
    echo ">>> Waiting for deployment..."

    # Wait for AgentRuntime
    echo "    Waiting for AgentRuntime to be ready..."
    kubectl wait --for=jsonpath='{.status.phase}'=Running agentruntime/discord-runtime -n ${NS} --timeout=120s || {
        echo "    ⚠ AgentRuntime not ready after 120s"
        echo "    Check logs: kubectl logs -n ${NS} -l app=aiagent-manager"
    }

    # Wait for Pod
    echo "    Waiting for Pod to be running..."
    sleep 5
    kubectl wait --for=condition=Ready pod -l runtime=discord-runtime -n ${NS} --timeout=60s || {
        echo "    ⚠ Pod not ready after 60s"
        kubectl get pods -n ${NS} -l runtime=discord-runtime
    }

    echo ""
    echo ">>> Deployment Status"
    kubectl get agentruntime discord-runtime -n ${NS}
    kubectl get aiagent discord-bot-1 -n ${NS}
    kubectl get pods -n ${NS} -l runtime=discord-runtime
}

show_usage() {
    echo ""
    echo "=================================================="
    echo "Discord Bot Usage Guide"
    echo "=================================================="

    echo ""
    echo ">>> Your Discord Bot is now deployed!"
    echo ""
    echo ">>> To use the bot in Discord:"
    echo "    1. Add the bot to your Discord server:"
    echo "       - Go to Discord Developer Portal"
    echo "       - OAuth2 > URL Generator"
    echo "       - Select 'bot' scope"
    echo "       - Copy and open the invite link"
    echo ""
    echo "    2. Interact with the bot:"
    echo "       - Use command prefix: ${COMMAND_PREFIX}"
    echo "       - Example: ${COMMAND_PREFIX}help"
    echo "       - Example: ${COMMAND_PREFIX}chat Hello!"
    echo ""
    echo ">>> Whitelist Settings:"
    if [ -n "$DISCORD_USER_IDS" ]; then
        echo "    - Only these users can interact with the bot:"
        for id in $(echo "$DISCORD_USER_IDS" | tr ',' ' '); do
            echo "      User ID: ${id}"
        done
    else
        echo "    - All users can interact (no whitelist)"
    fi
    if [ -n "$DISCORD_GUILD_ID" ] || [ -n "$DISCORD_GUILD_ID_INPUT" ]; then
        GUILD="${DISCORD_GUILD_ID:-$DISCORD_GUILD_ID_INPUT}"
        echo "    - Bot restricted to guild: ${GUILD}"
    else
        echo "    - Bot works in all guilds/servers"
    fi

    echo ""
    echo ">>> Troubleshooting:"
    echo "    Check bot logs:"
    echo "      kubectl logs -n ${NS} discord-runtime-runtime -c agent-handler"
    echo ""
    echo "    Check manager logs:"
    echo "      kubectl logs -n ${NS} deployment/aiagent-manager"
    echo ""
    echo "    Restart the bot:"
    echo "      kubectl rollout restart deployment/aiagent-manager -n ${NS}"
    echo ""
    echo "    Remove deployment:"
    echo "      ${SCRIPT_DIR}/deploy-openclaw-discord.sh --cleanup"

    echo ""
    echo "=================================================="
    echo "Happy chatting! 🤖"
    echo "=================================================="
}

show_config() {
    echo ""
    echo ">>> Testing configuration (dry-run)..."

    collect_credentials
    generate_config

    echo ""
    echo ">>> Generated Configuration Files"
    echo "    Location: ${TEMP_DIR}"
    echo ""
    echo "    Files created:"
    ls -la "${TEMP_DIR}"

    echo ""
    echo ">>> secrets.yaml preview:"
    cat "${TEMP_DIR}/secrets.yaml" | sed 's/token: .*/token: [REDACTED]/' | sed 's/api-key: .*/api-key: [REDACTED]/'

    echo ""
    echo ">>> agent.yaml preview:"
    cat "${TEMP_DIR}/agent.yaml"

    # Cleanup temp files
    rm -rf "${TEMP_DIR}"
}

# ============================================================
# Main
# ============================================================

case "${1:-}" in
    "--help")
        show_help
        ;;
    "--status")
        check_cluster
        show_status
        ;;
    "--cleanup")
        check_cluster
        cleanup
        ;;
    "--show-config")
        check_cluster
        show_config
        ;;
    *)
        check_cluster
        collect_credentials
        generate_config
        deploy
        show_usage

        # Cleanup temp files after successful deployment
        rm -rf "${TEMP_DIR}"
        ;;
esac

echo ""
echo "Done."