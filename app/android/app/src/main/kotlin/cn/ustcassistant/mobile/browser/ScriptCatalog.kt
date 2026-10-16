package cn.ustcassistant.mobile.browser

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom

/** Only bundled, fixed operations. Neither Flutter nor a web page supplies JS. */
internal class ScriptCatalog(context: Context) {
    private val jw = context.assets.open("ustc/jw_probe.js").bufferedReader().use { it.readText() }
    private val login = context.assets.open("ustc/jw_login.js").bufferedReader().use { it.readText() }
    private val young = context.assets.open("ustc/young_transport.js").bufferedReader().use { it.readText() }
    val command = token()
    val reply = token()
    val pageCommand = token()
    val pageReply = token()
    val pageFunction = "__ustc_" + token()

    fun privateBootstrap(policy: SchoolPolicy): String = """
        (function(){'use strict';if(this!==this.top)return;
        const native=__ustcSourceNative, stringify=JSON.stringify, parse=JSON.parse;
        const define=Object.defineProperty, create=Object.create, freeze=Object.freeze;
        const command=${q(command)}, reply=${q(reply)}, doc=document;
        let login=null, loginOperation=0, probe=false;
        let serial=0, loginSerial=0, loginEntry=null, probeSerial=0, probeEntry=null, navigationGuard=false;
        let currentEntry=null, entryId=null, nav=null;
        const apply=Reflect.apply;
        try{
          nav=globalThis.navigation;
          currentEntry=Object.getOwnPropertyDescriptor(Navigation.prototype,'currentEntry').get;
          entryId=Object.getOwnPropertyDescriptor(NavigationHistoryEntry.prototype,'id').get;
          apply(EventTarget.prototype.addEventListener,nav,['navigate',function(){++serial;}]);
          navigationGuard=!!nav;
        }catch(_){}
        function entry(){return apply(entryId,apply(currentEntry,nav,[]),[]);}
        function loginCurrent(){return navigationGuard&&serial===loginSerial&&entry()===loginEntry;}
        function probeCurrent(){return navigationGuard&&serial===probeSerial&&entry()===probeEntry;}
        function envelope(value){const out=create(null);out.reply=reply;out.value=value;return stringify(out);}
        define(this,'__ustcAndroidPrivate',{value:freeze(function(key,a){
          if(key!==command || document!==doc || this!==this.top)throw new Error('stale');
          switch(a.method){
            case 'advance':
              if(!navigationGuard)return envelope('contextUnavailable');
              if(loginOperation!==a.operation){loginSerial=serial;loginEntry=entry();login=($login)(this.location.href,${q(policy.casOrigin)},${q(policy.businessOrigin)},loginCurrent);loginOperation=a.operation;}
              return envelope(login.advance());
            case 'submit':
              if(!login || loginOperation!==a.operation)throw new Error('stale');
              loginOperation=0;
              return envelope(login.submit(a.username,a.password));
            case 'probe':
              if(a.action==='start'||a.action==='data'||a.action==='collect'){probeSerial=serial;probeEntry=entry();}
              if(!probe){($jw).call(this,${q(policy.businessOrigin)},command,reply,a.selfRouteId,probeCurrent);probe=true;}
              const api=this.__ustcJwProbeV1;
              return envelope(api[a.action](command,a.operation,a.semesterId));
            default:throw new Error('invalid');
          }
        }),writable:false,configurable:false});
        native.postMessage('ready');
        apply(EventTarget.prototype.addEventListener,this,['pageshow',function(e){
          if(e.isTrusted&&e.persisted)native.postMessage('ready');
        }]);
        }).call(globalThis);
    """.trimIndent()

    fun pageBootstrap(policy: SchoolPolicy): String = """
        (function(){'use strict';if(this!==this.top)return;
        const stringify=JSON.stringify, create=Object.create, define=Object.defineProperty, freeze=Object.freeze;
        const native=__ustcSourcePage, post=native.postMessage.bind(native);
        const key=${q(pageCommand)}, reply=${q(pageReply)};
        const api=($young)(${q(policy.businessOrigin)},key,reply);
        define(this,${q(pageFunction)},{value:freeze(function(cap,a){
          if(cap!==key)throw new Error('invalid');
          const out=create(null);out.reply=reply;out.call=a.call;
          try{switch(a.method){
            case 'prepare':out.value=api.prepare(a.page);break;
            case 'navigationReady':out.value=api.navigationReady();break;
            case 'start':out.value=api.start(a.operation);break;
            case 'dispatch':out.value=api.dispatch(a.operation,a.step,a.endpoint,a.page,a.day);break;
            case 'poll':out.value=api.poll(a.operation,a.step);break;
            case 'finish':out.value=api.finish(a.operation);break;
            default:throw new Error('invalid');
          }}catch(e){out.error=create(null);out.error.code=e&&e.code;out.error.reason=e&&e.reason;}
          post(stringify(out));return null;
        }),writable:false,configurable:false});
        }).call(globalThis);
    """.trimIndent()

    fun privateCall(args: JSONObject): String = "globalThis.__ustcAndroidPrivate(${q(command)},$args)"
    fun pageCall(args: JSONObject): String = "this[${q(pageFunction)}](${q(pageCommand)},$args)"

    fun unwrap(raw: String?, page: Boolean = false): JSONObject {
        // evaluateJavascript/executeJavaScript encode a returned JS string once.
        require(raw != null && raw.length <= 4 * 1024 * 1024)
        val decoded = JSONArray("[$raw]").get(0)
        require(decoded is String && decoded.length <= 2 * 1024 * 1024)
        val envelope = JSONObject(decoded)
        require(envelope.optString("reply") == if (page) pageReply else reply)
        require(envelope.length() == 2)
        return envelope
    }

    companion object {
        fun q(value: String): String = JSONObject.quote(value)
        private fun token(): String {
            val bytes = ByteArray(24).also { SecureRandom().nextBytes(it) }
            return bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
        }
    }
}
