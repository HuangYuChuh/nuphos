package ai.nuphos.android.ui.agent

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.nuphos.android.data.AgentRuntime
import ai.nuphos.android.data.RuntimeDevice
import ai.nuphos.android.data.RuntimeQuota
import ai.nuphos.android.session.runtimeGroups
import ai.nuphos.android.ui.components.RuntimeMark

/** Browsing a computer never changes the runtime. Both composers use this selector. */
@Composable
internal fun RuntimeChoiceList(
    runtimes: List<AgentRuntime>, selectedId: String?, quotas: Map<String, RuntimeQuota>,
    enabled: Boolean, devices: List<RuntimeDevice> = emptyList(), onDetail: ((AgentRuntime) -> Unit)? = null, onSelect: (AgentRuntime) -> Unit,
) {
    val groups = runtimeGroups(runtimes, devices)
    var expanded by remember(selectedId) { mutableStateOf<String?>(null) }
    var initialized by remember(selectedId) { mutableStateOf(false) }
    LaunchedEffect(groups.map { it.key }, selectedId) {
        if (!initialized && groups.isNotEmpty()) {
            expanded = groups.firstOrNull { group -> group.runtimes.any { it.id == selectedId } }?.key ?: groups.first().key
            initialized = true
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        groups.forEach { group ->
            Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow) {
                Column {
                    Surface(onClick = { expanded = if (expanded == group.key) null else group.key },
                        color = MaterialTheme.colorScheme.surfaceContainerLow) {
                        Row(Modifier.fillMaxWidth().padding(20.dp), verticalAlignment = Alignment.Top,
                            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Icon(if (group.key == "cloud") Icons.Outlined.Cloud else Icons.Outlined.Computer, null)
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(if (group.key == "cloud") "Cloud" else group.title, style = MaterialTheme.typography.titleMedium)
                                Text("${group.runtimes.size} runtimes" + if (group.runtimes.any { it.id == selectedId }) " · Current" else "",
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                group.device?.takeIf { it.online && it.metricsStatus == "live" }?.let { device ->
                                    Text("CPU ${device.cpuPercent?.toInt()?.let { "$it%" } ?: "unavailable"} · MEM ${device.memory?.percent ?: "—"}% · DISK ${device.disk?.percent ?: "—"}%",
                                        style = MaterialTheme.typography.labelSmall)
                                }
                            }
                            Icon(if (expanded == group.key) Icons.Outlined.ExpandMore else Icons.Outlined.ChevronRight,
                                if (expanded == group.key) "Collapse computer" else "Expand computer")
                        }
                    }
                    if (expanded == group.key) group.runtimes.forEach { runtime ->
                        HorizontalDivider(Modifier.padding(start = 20.dp))
                        Surface(onClick = { onSelect(runtime) },
                            enabled = enabled && runtime.selectable && runtime.local?.online != false && group.device?.online != false,
                            color = MaterialTheme.colorScheme.surfaceContainerLow,
                            modifier = Modifier.fillMaxWidth().semantics { selected = runtime.id == selectedId; role = Role.RadioButton; contentDescription = if (runtime.id == selectedId) "Selected ${runtime.label}" else "Use ${runtime.label}" }) {
                            Row(Modifier.padding(horizontal = 20.dp, vertical = 12.dp).heightIn(min = 48.dp),
                                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                RuntimeMark(runtime.provider, 20.dp)
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Text(runtime.label, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(when (runtime.provider) { "codex" -> "Codex"; "claude-code" -> "Claude Code"; "grok" -> "Grok Build"; "opencode" -> "OpenCode"; else -> runtime.provider },
                                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    when {
                                        runtime.local?.online == false -> Text("Computer offline", style = MaterialTheme.typography.bodySmall)
                                        runtime.signedIn == false -> Text("Sign in required", style = MaterialTheme.typography.bodySmall)
                                        else -> RuntimeUsage(quotas[runtime.id], compact = true)
                                    }
                                }
                                if (onDetail != null) IconButton(onClick = { onDetail(runtime) }) { Icon(Icons.Outlined.Info, "Details for ${runtime.label}") }
                                if (runtime.id == selectedId) Icon(Icons.Outlined.Check, "Selected runtime")
                            }
                        }
                    }
                }
            }
        }
    }
}
