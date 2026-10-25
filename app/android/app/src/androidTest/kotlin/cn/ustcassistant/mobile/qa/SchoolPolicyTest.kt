package cn.ustcassistant.mobile.qa

import androidx.test.ext.junit.runners.AndroidJUnit4
import cn.ustcassistant.mobile.browser.SchoolPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SchoolPolicyTest {
    @Test
    fun productionPoliciesUseExactOriginsAndUpgradeOnlyRegisteredHttpHosts() {
        val jw = SchoolPolicy.fromArguments(
            arguments(
                source = "jw",
                initialUrl = "https://jw.ustc.edu.cn/",
                origins = listOf(
                    "https://jw.ustc.edu.cn",
                    "https://passport.ustc.edu.cn",
                    "https://id.ustc.edu.cn",
                    "https://analytics.ustc.edu.cn",
                ),
            ),
            qa = false,
        )
        assertEquals("jw", jw.source)
        assertFalse(jw.fixture)
        assertEquals("https://jw.ustc.edu.cn", jw.businessOrigin)
        assertEquals("https://id.ustc.edu.cn", jw.casOrigin)
        jw.origins.forEach { origin ->
            assertTrue(jw.navigation("$origin/path").allowed)
        }

        val upgrade = jw.navigation(
            "http://jw.ustc.edu.cn:80/for-std/exam%2Darrange?next=%2Ftable#part%20one",
        )
        assertFalse(upgrade.allowed)
        assertEquals(
            "https://jw.ustc.edu.cn/for-std/exam%2Darrange?next=%2Ftable#part%20one",
            upgrade.upgradeUrl,
        )
        assertEquals("jw", upgrade.site)
        assertEquals("http", upgrade.scheme)
        assertTrue(jw.isCas("https://id.ustc.edu.cn:443/cas/login?service=fixture"))
        assertFalse(jw.isCas("https://id.ustc.edu.cn/cas/login/"))

        val young = SchoolPolicy.fromArguments(
            arguments(
                source = "young",
                initialUrl = "https://young.ustc.edu.cn/login/",
                origins = listOf(
                    "https://young.ustc.edu.cn",
                    "https://passport.ustc.edu.cn",
                    "https://ucas.ustc.edu.cn",
                    "https://id.ustc.edu.cn",
                    "https://analytics.ustc.edu.cn",
                ),
            ),
            qa = false,
        )
        assertTrue(young.navigation("https://ucas.ustc.edu.cn/continue").allowed)
        assertEquals("identity", young.site("https://id.ustc.edu.cn/cas/login"))
        assertEquals("gateway", young.site("https://analytics.ustc.edu.cn/"))
    }

    @Test
    fun rejectsSimilarHostsAbnormalPortsUserInfoBackslashesAndOtherSchemes() {
        val policy = jwPolicy()
        val rejected = listOf(
            "https://jw.ustc.edu.cn.evil.example/",
            "https://jw.ustc.edu.cn:444/",
            "http://jw.ustc.edu.cn:8080/",
            "https://jw.ustc.edu.cn@evil.example/",
            "https://jw.ustc.edu.cn\\\\evil.example/",
            "javascript:alert(1)",
            "https://jw.ustc.edu.cn/line\nbreak",
        )
        rejected.forEach { url ->
            val decision = policy.navigation(url)
            assertFalse("Unexpectedly allowed $url", decision.allowed)
            assertNull(decision.upgradeUrl)
        }
        assertEquals("other", policy.navigation("javascript:alert(1)").scheme)
        assertEquals("unknown", policy.site("https://jw.ustc.edu.cn.evil.example/"))
        assertNull(policy.origin("https://user@jw.ustc.edu.cn/"))
        assertEquals("https://jw.ustc.edu.cn", policy.origin("https://JW.USTC.EDU.CN:443/"))

        expectInvalid(
            arguments(
                source = "jw",
                initialUrl = "https://jw.ustc.edu.cn/",
                origins = listOf(
                    "https://jw.ustc.edu.cn",
                    "https://passport.ustc.edu.cn",
                    "https://id.ustc.edu.cn",
                    "https://analytics.ustc.edu.cn",
                    "https://evil.ustc.edu.cn",
                ),
            ),
            qa = false,
        )
    }

    @Test
    fun releaseIdentityRejectsFixturesAndProductionArgumentsStayFixed() {
        val fixtureArgs = arguments(
            source = "jw",
            initialUrl = "http://127.0.0.1:43127/fixture",
            origins = listOf("http://127.0.0.1:43127"),
            testMode = true,
        )
        expectInvalid(fixtureArgs, qa = false)
        expectInvalid(fixtureArgs + ("source" to "other"), qa = true)
        expectInvalid(
            arguments(
                source = "jw",
                initialUrl = "https://jw.ustc.edu.cn/extra",
                origins = jwOrigins(),
            ),
            qa = true,
        )
        expectInvalid(
            arguments(
                source = "jw",
                initialUrl = "https://jw.ustc.edu.cn/",
                origins = jwOrigins().dropLast(1) + "https://analytics.ustc.edu.cn:444",
            ),
            qa = true,
        )
    }

    @Test
    fun fixtureAcceptsSeveralDeclaredLoopbackOriginsAndOnlyTheirPorts() {
        val policy = SchoolPolicy.fromArguments(
            arguments(
                source = "young",
                initialUrl = "http://127.0.0.1:65535/fixture/start",
                origins = listOf(
                    "http://127.0.0.1:65535",
                    "https://127.0.0.1:1",
                    "http://127.0.0.1:2",
                    "https://127.0.0.1:3",
                ),
                testMode = true,
            ),
            qa = true,
        )
        assertTrue(policy.fixture)
        assertEquals("young", policy.source)
        assertEquals("http://127.0.0.1:65535", policy.businessOrigin)
        assertEquals(policy.businessOrigin, policy.casOrigin)
        assertEquals(4, policy.origins.size)
        assertEquals("fixture", policy.site("https://127.0.0.1:1/next"))
        assertTrue(policy.navigation("https://127.0.0.1:1/next").allowed)

        val undeclaredPort = policy.navigation("http://127.0.0.1:4/next")
        assertFalse(undeclaredPort.allowed)
        assertNull(undeclaredPort.upgradeUrl)
        assertFalse(policy.navigation("http://localhost:65535/fixture").allowed)

        val standardPort = SchoolPolicy.fromArguments(
            arguments(
                source = "jw",
                initialUrl = "http://127.0.0.1:80/fixture",
                origins = listOf("http://127.0.0.1:80"),
                testMode = true,
            ),
            qa = true,
        )
        assertEquals(setOf("http://127.0.0.1"), standardPort.origins)
        assertTrue(standardPort.navigation("http://127.0.0.1/fixture").allowed)
    }

    @Test
    fun fixtureRejectsBadPortsOriginsDuplicatesAndMoreThanFourOrigins() {
        val initialUrl = "http://127.0.0.1:43127/fixture"
        val invalidOrigins = listOf(
            "http://127.0.0.1",
            "http://127.0.0.1:0",
            "http://127.0.0.1:65536",
            "http://localhost:43127",
            "http://127.0.0.2:43127",
            "http://127.0.0.1:43127/path",
            "http://127.0.0.1:43127?query=1",
            "http://127.0.0.1:43127#fragment",
            "http://user@127.0.0.1:43127",
            "http://127.0.0.1\\\\evil.example:43127",
        )
        invalidOrigins.forEach { invalidOrigin ->
            expectInvalid(
                arguments(
                    source = "jw",
                    initialUrl = initialUrl,
                    origins = listOf(invalidOrigin),
                    testMode = true,
                ),
                qa = true,
            )
        }

        expectInvalid(
            arguments(
                source = "jw",
                initialUrl = initialUrl,
                origins = listOf(
                    "http://127.0.0.1:43127",
                    "http://127.0.0.1:43127",
                ),
                testMode = true,
            ),
            qa = true,
        )
        expectInvalid(
            arguments(
                source = "jw",
                initialUrl = initialUrl,
                origins = (43127..43131).map { "http://127.0.0.1:$it" },
                testMode = true,
            ),
            qa = true,
        )
        expectInvalid(
            arguments(
                source = "jw",
                initialUrl = "http://127.0.0.1:43127/fixture?query=1",
                origins = listOf("http://127.0.0.1:43127"),
                testMode = true,
            ),
            qa = true,
        )
        expectInvalid(
            arguments(
                source = "jw",
                initialUrl = "http://127.0.0.1:43127/fixture#fragment",
                origins = listOf("http://127.0.0.1:43127"),
                testMode = true,
            ),
            qa = true,
        )
        expectInvalid(
            arguments(
                source = "jw",
                initialUrl = "http://127.0.0.1:43128/fixture",
                origins = listOf("http://127.0.0.1:43127"),
                testMode = true,
            ),
            qa = true,
        )
    }

    @Test
    fun fixedPageEnumsResolveOnlyToApprovedPaths() {
        val jw = jwPolicy()
        assertEquals(
            "https://jw.ustc.edu.cn/for-std/course-table",
            jw.jwLauncher("courseTable"),
        )
        assertEquals(
            "https://jw.ustc.edu.cn/for-std/exam-arrange",
            jw.jwLauncher("examArrange"),
        )
        expectFailure { jw.jwLauncher("anything") }

        val young = SchoolPolicy.fromArguments(
            arguments(
                source = "young",
                initialUrl = "https://young.ustc.edu.cn/login/",
                origins = listOf(
                    "https://young.ustc.edu.cn",
                    "https://passport.ustc.edu.cn",
                    "https://ucas.ustc.edu.cn",
                    "https://id.ustc.edu.cn",
                    "https://analytics.ustc.edu.cn",
                ),
            ),
            qa = false,
        )
        assertEquals(
            "https://young.ustc.edu.cn/login/sc-wisdom-group-learning/myproject/SignUp",
            young.youngPage("activities"),
        )
        assertEquals(
            "https://young.ustc.edu.cn/login/sc-wisdom-group-learning/personalInformation/mySchedule",
            young.youngPage("calendar"),
        )
        expectFailure { young.youngPage("other") }
        expectFailure { jw.youngPage("activities") }
    }

    private fun jwPolicy(): SchoolPolicy = SchoolPolicy.fromArguments(
        arguments(
            source = "jw",
            initialUrl = "https://jw.ustc.edu.cn/",
            origins = jwOrigins(),
        ),
        qa = false,
    )

    private fun jwOrigins(): List<String> = listOf(
        "https://jw.ustc.edu.cn",
        "https://passport.ustc.edu.cn",
        "https://id.ustc.edu.cn",
        "https://analytics.ustc.edu.cn",
    )

    private fun arguments(
        source: String,
        initialUrl: String,
        origins: List<String>,
        testMode: Boolean = false,
    ): Map<String, Any> = mapOf(
        "source" to source,
        "testMode" to testMode,
        "initialUrl" to initialUrl,
        "allowedOrigins" to origins,
    )

    private fun expectInvalid(arguments: Map<*, *>, qa: Boolean) {
        expectFailure { SchoolPolicy.fromArguments(arguments, qa) }
    }

    private fun expectFailure(action: () -> Unit) {
        try {
            action()
            fail("Expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
            // Expected rejection.
        }
    }
}
