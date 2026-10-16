package cn.ustcassistant.mobile.browser

import java.net.URI
import java.net.URISyntaxException
import java.util.Collections
import java.util.LinkedHashSet
import java.util.Locale

internal data class NavigationDecision(
    val allowed: Boolean,
    val upgradeUrl: String? = null,
    val site: String = "unknown",
    val scheme: String = "other",
)

/** A document-navigation policy for the fixed JW and Young school sources. */
internal class SchoolPolicy private constructor(
    val source: String,
    val fixture: Boolean,
    val initialUrl: String,
    origins: Set<String>,
    val businessOrigin: String,
    val casOrigin: String,
) {
    val origins: Set<String> = Collections.unmodifiableSet(LinkedHashSet(origins))

    fun origin(url: String): String? = parseWebUri(url)?.let(::canonicalOrigin)

    fun navigation(url: String): NavigationDecision {
        val scheme = schemeOf(url)
        val site = site(url)
        val uri = parseWebUri(url)
            ?: return NavigationDecision(false, site = site, scheme = scheme)
        val parsedOrigin = canonicalOrigin(uri)
            ?: return NavigationDecision(false, site = site, scheme = scheme)

        if (fixture) {
            return NavigationDecision(
                allowed = parsedOrigin in origins,
                site = site,
                scheme = scheme,
            )
        }

        if (scheme == "https") {
            return NavigationDecision(parsedOrigin in origins, site = site, scheme = scheme)
        }

        if (scheme == "http" && (uri.port == -1 || uri.port == 80)) {
            val host = canonicalHost(uri)
                ?: return NavigationDecision(false, site = site, scheme = scheme)
            val secureOrigin = "https://$host"
            if (secureOrigin in origins) {
                return NavigationDecision(
                    allowed = false,
                    upgradeUrl = upgradeToHttps(uri, host),
                    site = site,
                    scheme = scheme,
                )
            }
        }

        return NavigationDecision(false, site = site, scheme = scheme)
    }

    fun jwLauncher(page: String): String {
        require(source == "jw")
        val path = when (page) {
            "courseTable" -> "/for-std/course-table"
            "examArrange" -> "/for-std/exam-arrange"
            else -> throw IllegalArgumentException("Unknown JW page")
        }
        return businessOrigin + path
    }

    fun youngPage(page: String): String {
        require(source == "young")
        val path = when (page) {
            "activities" -> "/login/sc-wisdom-group-learning/myproject/SignUp"
            "calendar" -> "/login/sc-wisdom-group-learning/personalInformation/mySchedule"
            else -> throw IllegalArgumentException("Unknown Young page")
        }
        return businessOrigin + path
    }

    fun site(url: String): String {
        val uri = parseWebUri(url) ?: return "unknown"
        val host = canonicalHost(uri) ?: return "unknown"
        if (fixture) {
            val parsedOrigin = canonicalOrigin(uri) ?: return "unknown"
            return if (parsedOrigin in origins) "fixture" else "unknown"
        }

        val knownSite = HOST_SITES[host] ?: return "unknown"
        return if (origins.any { originHost(it) == host }) knownSite else "unknown"
    }

    fun isCas(url: String): Boolean {
        val uri = parseWebUri(url) ?: return false
        return canonicalOrigin(uri) == casOrigin && uri.rawPath == CAS_PATH
    }

    companion object {
        private const val JW_INITIAL_URL = "https://jw.ustc.edu.cn/"
        private const val YOUNG_INITIAL_URL = "https://young.ustc.edu.cn/login/"
        private const val PRODUCTION_CAS_ORIGIN = "https://id.ustc.edu.cn"
        private const val CAS_PATH = "/cas/login"

        private val JW_ORIGINS = linkedSetOf(
            "https://jw.ustc.edu.cn",
            "https://passport.ustc.edu.cn",
            "https://id.ustc.edu.cn",
            "https://analytics.ustc.edu.cn",
        )
        private val YOUNG_ORIGINS = linkedSetOf(
            "https://young.ustc.edu.cn",
            "https://passport.ustc.edu.cn",
            "https://ucas.ustc.edu.cn",
            "https://id.ustc.edu.cn",
            "https://analytics.ustc.edu.cn",
        )
        private val HOST_SITES = mapOf(
            "jw.ustc.edu.cn" to "jw",
            "young.ustc.edu.cn" to "young",
            "passport.ustc.edu.cn" to "passport",
            "id.ustc.edu.cn" to "identity",
            "ucas.ustc.edu.cn" to "ucas",
            "analytics.ustc.edu.cn" to "gateway",
        )
        private val SCHEME_PREFIX = Regex("^([A-Za-z][A-Za-z0-9+.-]*):")

        fun fromArguments(args: Map<*, *>, qa: Boolean): SchoolPolicy {
            val source = args["source"] as? String ?: invalidArguments()
            if (source != "jw" && source != "young") invalidArguments()
            val testMode = args["testMode"] as? Boolean ?: invalidArguments()
            val initialUrl = args["initialUrl"] as? String ?: invalidArguments()
            val rawOrigins = args["allowedOrigins"] as? List<*> ?: invalidArguments()
            val suppliedOrigins = rawOrigins.map { it as? String ?: invalidArguments() }

            if (testMode) {
                if (!qa) invalidArguments()
                val origins = fixtureOrigins(suppliedOrigins)
                val initial = parseWebUri(initialUrl) ?: invalidArguments()
                if (canonicalHost(initial) != LOOPBACK_HOST ||
                    initial.port !in 1..65535 ||
                    initial.rawQuery != null ||
                    initial.rawFragment != null
                ) {
                    invalidArguments()
                }
                val businessOrigin = canonicalOrigin(initial) ?: invalidArguments()
                if (businessOrigin !in origins) invalidArguments()
                return SchoolPolicy(
                    source = source,
                    fixture = true,
                    initialUrl = initialUrl,
                    origins = origins,
                    businessOrigin = businessOrigin,
                    casOrigin = businessOrigin,
                )
            }

            val expectedOrigins = if (source == "jw") JW_ORIGINS else YOUNG_ORIGINS
            val origins = productionOrigins(suppliedOrigins, expectedOrigins)
            val expectedInitial = if (source == "jw") JW_INITIAL_URL else YOUNG_INITIAL_URL
            if (initialUrl != expectedInitial) invalidArguments()
            val initial = parseWebUri(initialUrl) ?: invalidArguments()
            val businessOrigin = canonicalOrigin(initial) ?: invalidArguments()
            if (businessOrigin !in origins) invalidArguments()
            if (PRODUCTION_CAS_ORIGIN !in origins) invalidArguments()

            return SchoolPolicy(
                source = source,
                fixture = false,
                initialUrl = initialUrl,
                origins = origins,
                businessOrigin = businessOrigin,
                casOrigin = PRODUCTION_CAS_ORIGIN,
            )
        }

        private fun productionOrigins(
            candidates: List<String>,
            expected: Set<String>,
        ): Set<String> {
            val normalized = candidates.map { candidate ->
                val uri = parseWebUri(candidate) ?: invalidArguments()
                if (uri.scheme.lowercase(Locale.ROOT) != "https" ||
                    !isOriginOnly(uri)
                ) {
                    invalidArguments()
                }
                canonicalOrigin(uri) ?: invalidArguments()
            }
            val result = LinkedHashSet(normalized)
            if (result.size != normalized.size || result != expected) invalidArguments()
            return result
        }

        private fun fixtureOrigins(candidates: List<String>): Set<String> {
            if (candidates.isEmpty() || candidates.size > 4) invalidArguments()
            val normalized = candidates.map { candidate ->
                val uri = parseWebUri(candidate) ?: invalidArguments()
                if (canonicalHost(uri) != LOOPBACK_HOST ||
                    uri.port !in 1..65535 ||
                    !isOriginOnly(uri)
                ) {
                    invalidArguments()
                }
                canonicalOrigin(uri) ?: invalidArguments()
            }
            val result = LinkedHashSet(normalized)
            if (result.size != normalized.size) invalidArguments()
            return result
        }

        private fun isOriginOnly(uri: URI): Boolean =
            uri.rawPath.isNullOrEmpty() && uri.rawQuery == null && uri.rawFragment == null

        private fun parseWebUri(raw: String): URI? {
            if (raw.isEmpty() || raw.any { it.isIsoControl() || it == '\\' }) return null
            val uri = try {
                URI(raw)
            } catch (_: URISyntaxException) {
                return null
            } catch (_: IllegalArgumentException) {
                return null
            }
            val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return null
            if (uri.isOpaque || (scheme != "http" && scheme != "https")) return null
            if (uri.rawAuthority.isNullOrEmpty() || uri.rawUserInfo != null) return null
            if (uri.rawAuthority!!.endsWith(":")) return null
            if (canonicalHost(uri) == null) return null
            if (uri.port < -1 || uri.port > 65535) return null
            return uri
        }

        private fun canonicalOrigin(uri: URI): String? {
            val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return null
            if (scheme != "http" && scheme != "https") return null
            val host = canonicalHost(uri) ?: return null
            val port = uri.port
            if (port < -1 || port > 65535) return null
            val defaultPort = if (scheme == "https") 443 else 80
            val portSuffix = if (port == -1 || port == defaultPort) "" else ":$port"
            return "$scheme://$host$portSuffix"
        }

        private fun canonicalHost(uri: URI): String? {
            val host = uri.host ?: return null
            val normalized = host.lowercase(Locale.ROOT)
            if (normalized.contains(':')) {
                val address = normalized.removePrefix("[").removeSuffix("]")
                if (address.isEmpty() || address.any {
                        !(it in '0'..'9' || it in 'a'..'f' || it == ':' || it == '.')
                    }
                ) {
                    return null
                }
                return if (normalized.startsWith("[") && normalized.endsWith("]")) {
                    normalized
                } else {
                    "[$normalized]"
                }
            }

            if (normalized.length > 253) return null
            val labels = normalized.split('.')
            if (labels.any { label ->
                    label.isEmpty() || label.length > 63 ||
                        label.startsWith('-') || label.endsWith('-') ||
                        label.any { !(it in 'a'..'z' || it in '0'..'9' || it == '-') }
                }
            ) {
                return null
            }
            return normalized
        }

        private fun originHost(origin: String): String? {
            val uri = parseWebUri(origin) ?: return null
            return canonicalHost(uri)
        }

        private fun upgradeToHttps(uri: URI, host: String): String = buildString {
            append("https://")
            append(host)
            append(uri.rawPath.orEmpty())
            uri.rawQuery?.let {
                append('?')
                append(it)
            }
            uri.rawFragment?.let {
                append('#')
                append(it)
            }
        }

        private fun schemeOf(raw: String): String {
            val scheme = SCHEME_PREFIX.find(raw)?.groupValues?.get(1)
                ?.lowercase(Locale.ROOT)
            return if (scheme == "http" || scheme == "https") scheme else "other"
        }

        private fun invalidArguments(): Nothing =
            throw IllegalArgumentException("Invalid school navigation policy arguments")

        private fun Char.isIsoControl(): Boolean = code < 0x20 || code in 0x7f..0x9f

        private const val LOOPBACK_HOST = "127.0.0.1"
    }
}
