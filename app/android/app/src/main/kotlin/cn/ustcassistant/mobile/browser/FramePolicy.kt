package cn.ustcassistant.mobile.browser

import org.json.JSONObject

/** Browser-enforced document embedding policy; ordinary resource traffic is unchanged. */
internal object FramePolicy {
    fun script(origins: Set<String>): String {
        val policy = "frame-src ${origins.sorted().joinToString(" ")}; object-src 'none'"
        return """
            (function(){'use strict';
              const doc=document, native=typeof __ustcFramePolicy==='undefined'?null:__ustcFramePolicy;
              const post=native?native.postMessage.bind(native):function(){};
              const listen=EventTarget.prototype.addEventListener, apply=Reflect.apply;
              const topFrame=this===this.top;
              try {
                // XML/SVG nodes named "meta" need not be HTMLMetaElements;
                // appending one without throwing does not install a policy.
                if(doc.contentType!=='text/html')throw new Error('unsupported');
                // Run in every frame, before parser-created frames or page scripts.
                // Chromium's parser owns html/head: remove only our temporary nodes.
                let root=doc.documentElement, ownRoot=false, ownHead=false;
                if(!root){root=doc.createElement('html');doc.appendChild(root);ownRoot=true;}
                let head=doc.head;
                if(!head){head=doc.createElement('head');root.insertBefore(head,root.firstChild);ownHead=true;}
                const meta=doc.createElement('meta');
                meta.setAttribute('http-equiv','Content-Security-Policy');
                meta.setAttribute('content',${JSONObject.quote(policy)});
                head.appendChild(meta);
                // A CSP policy remains active after its delivering meta is removed.
                if(ownRoot)doc.removeChild(root);else if(ownHead)root.removeChild(head);
                Object.defineProperty(this,'__ustcFramePolicyInstalled',
                  {value:true,writable:false,configurable:false});
                apply(listen,doc,['securitypolicyviolation',function(e){
                  if(e.isTrusted!==true||e.effectiveDirective!=='frame-src')return;
                  const uri=e.blockedURI;
                  const scheme=typeof uri==='string'&&uri.startsWith('https:')?'https':
                    typeof uri==='string'&&uri.startsWith('http:')?'http':'other';
                  post('blocked:'+scheme);
                },true]);
                if(topFrame){
                  post('installed');
                  apply(listen,this,['pageshow',function(e){if(e.isTrusted&&e.persisted)post('installed');}]);
                }
              } catch(_) {
                // No authentication or business action is admitted without a policy.
                this.stop();post('unavailable');
              }
            }).call(globalThis);
        """.trimIndent()
    }
}
