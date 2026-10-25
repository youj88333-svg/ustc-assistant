package cn.ustcassistant.mobile.browser

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom

/** Fixed, bundled operations installed in the ordinary top-page world. */
internal class ScriptCatalog(context: Context) {
    private val jw = context.assets.open("ustc/jw_probe.js").bufferedReader().use { it.readText() }
    private val login = context.assets.open("ustc/jw_login.js").bufferedReader().use { it.readText() }
    private val young = context.assets.open("ustc/young_transport.js").bufferedReader().use { it.readText() }

    val command = token()
    val reply = token()
    val pageCommand = token()
    val pageReply = token()
    val apiName = "__ustc_" + token()
    val pageApiName = "__ustc_" + token()
    private val messageCommand = token()

    fun bootstrap(policy: SchoolPolicy, url: String, generation: Long): String {
        val jwFactory = if (policy.source == "jw" && policy.origin(url) == policy.businessOrigin) "($jw)" else "null"
        val loginBootstrap = """
            (function(root){'use strict';
              const name=${q(apiName)}, command=${q(command)}, reply=${q(reply)};
              const generationStart=${generation}, casOrigin=${q(policy.casOrigin)},
                businessOrigin=${q(policy.businessOrigin)};
              const loginFactory=($login);
              const loginStates=['waiting','portalActivated','formReady','businessReady',
                'manualRequired','pageStructureChanged','challengeRequired','contextUnavailable','submitted'];
              let state=root[name];
              if(state){state.bind(command,generationStart);return true;}
              const doc=root.document;
              state={generation:generationStart,login:null,loginOperation:0,loginGeneration:-1,
                loginHref:'',probe:null,probeGeneration:-1,probeHref:'',secretResult:null};
              function bind(key,next){
                if(key!==command||!Number.isSafeInteger(next)||next<state.generation)throw new Error('stale');
                if(next!==state.generation){state.generation=next;state.login=null;
                  state.loginOperation=0;state.loginGeneration=-1;state.secretResult=null;}
                if(state.probe)state.probe.bindGeneration(command,next);
              }
              function call(key,a){
                const out=Object.create(null);out.reply=reply;
                try{
                  if(key!==command||!a||a.document!==state.generation||root.document!==doc||root!==root.top)
                    throw new Error('stale');
                  switch(a.method){
                    case 'advance': {
                      const href=root.location.href;
                      if(!state.login||state.loginOperation!==a.operation||
                          state.loginGeneration!==a.document||state.loginHref!==href){
                        const expectedGeneration=a.document;
                        state.login=loginFactory(href,casOrigin,businessOrigin,function(){
                          return state.generation===expectedGeneration&&root.document===doc&&
                            root.location.href===href&&root===root.top;
                        });
                        state.loginOperation=a.operation;state.loginGeneration=a.document;state.loginHref=href;
                      }
                      out.value=state.login.advance();break;
                    }
                    case 'probe': {
                      if(root.location.origin!==businessOrigin)throw new Error('stale');
                      const href=root.location.href, expectedGeneration=a.document;
                      state.probeGeneration=expectedGeneration;state.probeHref=href;
                      if(!state.probe){
                        const probeFactory=$jwFactory;
                        if(!probeFactory)throw new Error('unsupported');
                        state.probe=probeFactory.call(root,businessOrigin,command,reply,
                          typeof a.selfRouteId==='string'?a.selfRouteId:'',function(generation,expectedHref){
                            return state.generation===generation&&root.document===doc&&
                              root.location.href===expectedHref&&root===root.top;
                          },expectedGeneration);
                      }
                      state.probe.bindGeneration(command,expectedGeneration);
                      out.value=state.probe[a.action](command,a.operation,a.semesterId);break;
                    }
                    case 'secretResult': {
                      const ready=state.secretResult;
                      if(ready&&ready.operation===a.operation&&ready.document===a.document){
                        out.value=ready.state;state.secretResult=null;
                      }else out.value=null;
                      break;
                    }
                    default:throw new Error('invalid');
                  }
                  return JSON.stringify(out);
                }catch(error){
                  out.error=Object.create(null);
                  out.error.code=error&&error.code||'staleResult';
                  out.error.reason=error&&error.reason||'stampChanged';
                  return JSON.stringify(out);
                }
              }
              const api=Object.freeze({bind:bind,call:call});
              Object.defineProperty(root,name,{value:api,writable:false,configurable:false,enumerable:false});
              const messageCommand=${q(messageCommand)};
              root.addEventListener('message',function(event){
                if(!event||typeof event.data!=='string'||
                    root!==root.top||root.document!==doc||root.location.origin!==casOrigin||
                    root.location.pathname!=='/cas/login')return;
                let message;
                try{message=JSON.parse(event.data);}catch(_){return;}
                if(!message||message.command!==messageCommand||message.document!==state.generation||
                    message.document!==state.loginGeneration||message.operation!==state.loginOperation||
                    !Number.isSafeInteger(message.operation)||typeof message.username!=='string'||
                    typeof message.password!=='string'||!message.username||!message.password)return;
                const login=state.login;state.login=null;state.loginOperation=0;
                let value='manualRequired';
                try{if(login)value=login.submit(message.username,message.password);}catch(_){value='pageStructureChanged';}
                state.secretResult={operation:message.operation,document:message.document,
                  state:loginStates.indexOf(value)>=0?value:'manualRequired'};
                message.username='';message.password='';
              },false);
              return true;
            })(window);
        """.trimIndent()

        val youngContext = policy.source == "young" && policy.origin(url) == policy.businessOrigin &&
            Uri.parse(url).path?.startsWith("/login/sc-wisdom-group-learning") == true

        val youngBootstrap = """
            (function(root){'use strict';
              const name=${q(pageApiName)}, command=${q(pageCommand)}, reply=${q(pageReply)};
              const generationStart=${generation}, origin=${q(policy.businessOrigin)};
              const enabled=${youngContext};
              const transportFactory=($young);
              let state=root[name];
              if(state){state.bind(command,generationStart);return true;}
              if(!enabled||root!==root.top||root.location.origin!==origin)return true;
              const transport=transportFactory(origin,command,reply);
              let generation=generationStart;
              let activeOperation=null;
              function bind(key,next){
                if(key!==command||!Number.isSafeInteger(next)||next<generation)throw new Error('stale');
                if(next!==generation&&activeOperation!==null){
                  try{transport.finish(activeOperation);}catch(_){}
                  activeOperation=null;
                }
                generation=next;
              }
              function call(key,a){
                const out=Object.create(null);out.reply=reply;out.call=a.call;
                try{
                  if(key!==command||!a||a.document!==generation||root.document===null||root!==root.top)
                    throw new Error('stale');
                  switch(a.method){
                    case 'prepare':out.value=transport.prepare(a.page);break;
                    case 'navigationReady':out.value=transport.navigationReady();break;
                    case 'start':
                      out.value=transport.start(a.operation);activeOperation=a.operation;break;
                    case 'dispatch':
                      if(activeOperation!==a.operation)throw new Error('stale');
                      out.value=transport.dispatch(a.operation,a.step,a.endpoint,a.page,a.day);break;
                    case 'poll':
                      if(activeOperation!==a.operation)throw new Error('stale');
                      out.value=transport.poll(a.operation,a.step);break;
                    case 'finish':
                      if(activeOperation!==a.operation)throw new Error('stale');
                      out.value=transport.finish(a.operation);activeOperation=null;break;
                    default:throw new Error('invalid');
                  }
                  return JSON.stringify(out);
                }catch(error){
                  out.error=Object.create(null);
                  out.error.code=error&&error.code||'sourceFailed';
                  out.error.reason=error&&error.reason||'sourceFailure';
                  return JSON.stringify(out);
                }
              }
              state=Object.freeze({bind:bind,call:call});
              Object.defineProperty(root,name,{value:state,writable:false,configurable:false,enumerable:false});
              return true;
            })(window);
        """.trimIndent()
        return "$loginBootstrap\n$youngBootstrap"
    }

    fun rebind(generation: Long): String = """
        (function(){'use strict';
          const a=window[${q(apiName)}], y=window[${q(pageApiName)}];
          if(a)a.bind(${q(command)},$generation);
          if(y)y.bind(${q(pageCommand)},$generation);
          return true;
        })()
    """.trimIndent()

    fun apiCall(args: JSONObject): String =
        "window[${q(apiName)}].call(${q(command)},$args)"

    fun pageCall(args: JSONObject): String =
        "window[${q(pageApiName)}].call(${q(pageCommand)},$args)"

    fun credentialMessage(operation: Long, generation: Long, username: String, password: String): String =
        JSONObject().put("command", messageCommand).put("operation", operation)
            .put("document", generation).put("username", username).put("password", password).toString()

    fun unwrap(raw: String?, page: Boolean = false): JSONObject {
        require(raw != null && raw.length <= 4 * 1024 * 1024)
        val decoded = JSONArray("[$raw]").get(0)
        require(decoded is String && decoded.length <= 2 * 1024 * 1024)
        val envelope = JSONObject(decoded)
        require(envelope.optString("reply") == if (page) pageReply else reply)
        require(envelope.length() == (if (page) 3 else 2))
        if (page) require(envelope.optLong("call", -1) >= 0)
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
