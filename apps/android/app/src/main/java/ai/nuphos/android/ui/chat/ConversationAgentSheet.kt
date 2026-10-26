package ai.nuphos.android.ui.chat

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import ai.nuphos.android.data.AgentRuntime
import ai.nuphos.android.data.AgentRuntimeApi
import ai.nuphos.android.data.RuntimeQuota
import ai.nuphos.android.session.ChatSession
import ai.nuphos.android.ui.agent.RuntimeUsage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** The current usage stays readable even when changing agents is unavailable. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ConversationAgentSheet(
    session: ChatSession,
    token: String,
    quotas: Map<String, RuntimeQuota>,
    isCurrent: () -> Boolean,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val devices = ai.nuphos.android.ui.agent.rememberRuntimeDevices(token, session.teamId)
    var catalog by remember(session) { mutableStateOf<List<AgentRuntime>?>(null) }
    var error by remember(session) { mutableStateOf<String?>(null) }
    var refreshing by remember(session) { mutableStateOf(false) }
    var refresh by remember(session) { mutableIntStateOf(0) }
    var pendingLocal by remember(session) { mutableStateOf<AgentRuntime?>(null) }
    LaunchedEffect(session, token, refresh) {
        refreshing = true
        try {
            val loaded = AgentRuntimeApi(token, session.teamId).catalog()
            if (isCurrent()) { catalog = loaded; error = null }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { if (isCurrent()) error = e.message ?: "Could not load runtimes." }
        finally { refreshing = false }
    }
    fun move(target: AgentRuntime) {
        if (!isCurrent() || !session.canMoveAgent) return
        scope.launch {
            error = null
            try {
                session.moveAgent(target)
                if (isCurrent()) onDismiss()
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) {
                if (isCurrent()) {
                    error = e.message ?: "Could not switch runtimes. Refresh and try again."
                    // Reconcile ambiguous network failures without optimistically changing placement.
                    session.reloadFromServer()
                }
            }
        }
    }
    // Keep one expanded anchor and a stable viewport while the catalog loads or changes.
    // Content remains scrollable on short screens and with large text.
    ModalBottomSheet(
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        onDismissRequest = { if (!session.movingAgent) onDismiss() },
    ) {
        Column(Modifier.testTag("conversation-runtime-sheet").fillMaxWidth().fillMaxHeight().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Runtime", style = MaterialTheme.typography.titleLarge)
            Text(session.runtimeDeviceLabel ?: "Current runtime", style = MaterialTheme.typography.titleMedium)
            RuntimeUsage(session.runtimeId?.let { quotas[it] })
            if (session.movingAgent) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text("Switching runtime…") }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (session.canManage) {
                Text("Switch runtime", style = MaterialTheme.typography.titleMedium)
                if (!session.canMoveAgent && !session.movingAgent) Text("Wait for the current response or pending message to finish before switching runtimes.")
                if (refreshing) LinearProgressIndicator(Modifier.fillMaxWidth())
                val choices = catalog?.filter { session.isOwner || it.kind == "managed" }
                if (choices != null && choices.isEmpty()) Text("No available runtimes.")
                if (choices != null) ai.nuphos.android.ui.agent.RuntimeChoiceList(choices, session.runtimeId, quotas,
                    enabled = !refreshing && session.canMoveAgent, devices = devices, onSelect = { target ->
                        if (target.id == session.runtimeId) onDismiss()
                        else if (target.kind == "local") pendingLocal = target
                        else move(target)
                    })
                TextButton(enabled = !refreshing && !session.movingAgent, onClick = { refresh++ }) { Text("Refresh runtimes") }
            }
            TextButton(enabled = !session.movingAgent, onClick = onDismiss) { Text("Done") }
        }
    }
    pendingLocal?.let { target ->
        AlertDialog(onDismissRequest = { pendingLocal = null }, title = { Text("Move to ${target.label}?") },
            text = { Text("This runtime runs on your computer. After the move, anyone in this team can open this agent and run commands on your computer.") },
            confirmButton = { TextButton(enabled = isCurrent() && session.canMoveAgent, onClick = { pendingLocal = null; move(target) }) { Text("Move") } },
            dismissButton = { TextButton(onClick = { pendingLocal = null }) { Text("Cancel") } })
    }
}
