// New, disposable Windows SDK experiment. All URLs are synthetic loopback URLs.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

class Check {
    public string id, status, detail;
    public Check() {}
    public Check(string i, bool pass, string d) { id=i; status=pass?"pass":"fail"; detail=d; }
    public Check(string i, string s, string d) { id=i; status=s; detail=d; }
}
class Evidence {
    public string utc=DateTime.UtcNow.ToString("o"), sdk="1.0.3967.48", runtime;
    public string command="powershell -NoProfile -ExecutionPolicy Bypass -File verification/windows/run.ps1";
    public List<Check> checks=new List<Check>();
    public bool deletePending;
}
class NativeBrowserProcessFailureException : Exception {}
class Owner : IDisposable {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(SafeFileHandle file,StringBuilder result,uint size,uint flags);
    FileStream lease;
    public string Canonical;
    public static string Resolve(string path) {
        string full=Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
        string cursor=Path.GetPathRoot(full);
        foreach(string part in full.Substring(cursor.Length).Split(Path.DirectorySeparatorChar)) {
            if(part.Length==0) continue;
            cursor=Path.Combine(cursor,part);
            if((File.GetAttributes(cursor)&FileAttributes.ReparsePoint)!=0) throw new IOException("reparse_rejected");
        }
        using(SafeFileHandle handle=CreateFile(full,0x80,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
            if(handle.IsInvalid) throw new IOException("directory_handle_failed");
            var result=new StringBuilder(32768);
            uint size=GetFinalPathNameByHandle(handle,result,(uint)result.Capacity,0);
            if(size==0||size>=result.Capacity) throw new IOException("canonical_path_failed_win32_"+Marshal.GetLastWin32Error());
            return result.ToString();
        }
    }
    public Owner(string path) {
        Canonical=Resolve(path);
        // The actual canonical directory owns a real file handle. No name/hash mutex.
        lease=new FileStream(Path.Combine(path,".owner"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);
        if(!String.Equals(Canonical,Resolve(path),StringComparison.OrdinalIgnoreCase)) { Dispose(); throw new IOException("path_changed"); }
    }
    public void Dispose() { if(lease!=null) {lease.Dispose();lease=null;} }
}
class LocalServer : IDisposable {
    TcpListener listener;
    CancellationTokenSource cancellation=new CancellationTokenSource();
    public int Port;
    public int DeniedPort;
    public string CalScript;
    public bool CalWideFixture;
    public string DirectCalHeader;
    public Dictionary<string,int> Hits=new Dictionary<string,int>();
    public Dictionary<string,int> Writes=new Dictionary<string,int>();
    public LocalServer(bool dedicatedListener=false) {
        listener=new TcpListener(IPAddress.Loopback,0);listener.Start();
        Port=((IPEndPoint)listener.LocalEndpoint).Port;
        if(dedicatedListener)new Thread(Listen){IsBackground=true}.Start();else Task.Run((Action)Listen);
    }
    void Listen() {
        while(!cancellation.IsCancellationRequested) {
            try { var client=listener.AcceptTcpClient(); Task.Run(()=>Serve(client)); }
            catch(SocketException) { if(!cancellation.IsCancellationRequested) throw; }
            catch(ObjectDisposedException) { if(!cancellation.IsCancellationRequested) throw; }
        }
    }
    public int Count(string path) { lock(Hits) return Hits.ContainsKey(path)?Hits[path]:0; }
    public int CountWritten(string path) {lock(Writes)return Writes.ContainsKey(path)?Writes[path]:0;}
    public void Clear() {lock(Hits)Hits.Clear();lock(Writes)Writes.Clear();}
    void Serve(TcpClient client) {
        using(client) {
            client.ReceiveTimeout=3000;client.SendTimeout=3000;
            try {
                var stream=client.GetStream();
                // Synthetic server consumes only the first request line. No auth headers/body.
                var bytes=new List<byte>(); int next;
                while((next=stream.ReadByte())!=-1 && next!=10 && bytes.Count<4096) bytes.Add((byte)next);
                // Drain unexamined synthetic header bytes to avoid a TCP reset on close.
                // No decoding, inspection, retention, or body read occurs.
                int prior=0,prior2=0,prior3=0;
                for(int n=0;n<16384;n++) {int value=stream.ReadByte();if(value<0)break;if(prior3==13&&prior2==10&&prior==13&&value==10)break;prior3=prior2;prior2=prior;prior=value;}
                string[] line=Encoding.ASCII.GetString(bytes.ToArray()).Trim().Split(' ');
                string path=line.Length>1?line[1]:"/invalid";
                // Known static experiment paths only; query values never recorded.
                path=path.Split('?')[0]; lock(Hits) { if(!Hits.ContainsKey(path)) Hits[path]=0; Hits[path]++; }
                string type="text/html", extra="", body="<!doctype html><title>synthetic</title><p>safe local page</p>";
                int status=200;
                string denied="http://127.0.0.1:"+DeniedPort;
                if((path=="/storage"||path=="/landing")&&DirectCalHeader!=null)extra+="Connection-Allowlist: "+DirectCalHeader+"\r\n";
                if(path=="/redirect") {status=302;extra="Location: /landing\r\n";}
                if(path=="/redirect-denied") {status=302;extra="Location: "+denied+"/redirect-target\r\n";}
                if(path=="/frame") body="<!doctype html><iframe src='/frame-child'></iframe>";
                if(path=="/download") { type="application/octet-stream";extra="Content-Disposition: attachment; filename=synthetic.bin\r\n";body="synthetic-download"; }
                if(path=="/worker.js") {type="application/javascript";body="fetch('/worker-ok').catch(()=>{});fetch('"+denied+"/worker-denied').catch(()=>{});new WebSocket('ws://127.0.0.1:"+Port+"/worker-ws-ok');new WebSocket('ws://127.0.0.1:"+DeniedPort+"/worker-ws-denied');";}
                if(path=="/sw.js") {type="application/javascript";body="function probe(){return Promise.all([fetch('/sw-ok'),fetch('"+denied+"/sw-denied').catch(()=>{})]).then(()=>{if(typeof WebSocket!=='undefined'){fetch('/sw-ws-supported');new WebSocket('ws://127.0.0.1:"+Port+"/sw-ws-ok');new WebSocket('ws://127.0.0.1:"+DeniedPort+"/sw-ws-denied');}});}self.addEventListener('install',e=>e.waitUntil(self.skipWaiting()));self.addEventListener('activate',e=>e.waitUntil(self.clients.claim().then(probe)));self.addEventListener('message',e=>e.waitUntil(probe()));";}
                if(path=="/cdp-frame") body="<!doctype html><script>fetch('"+denied+"/cdp-frame-fetch-denied').catch(()=>{});let i=new Image();i.src='"+denied+"/cdp-frame-image-denied';new WebSocket('ws://127.0.0.1:"+Port+"/frame-ws-ok');new WebSocket('ws://127.0.0.1:"+DeniedPort+"/frame-ws-denied');new Worker('/worker.js');</script>";
                if(path=="/guard") {body=GuardMain();extra+="Content-Security-Policy: img-src 'none'\r\n";}
                if(path=="/guard-frame") {body=GuardContext("frame");extra+="Content-Security-Policy: img-src 'none'\r\n";}
                if(CalWideFixture&&(path=="/guard"||path=="/guard-frame"))extra+="Connection-Allowlist: (\"http://127.0.0.1:*/*\" \"https://127.0.0.1:*/*\"); redirects=allow; webrtc=allow\r\n";
                if(path=="/guard-worker.js") {type="application/javascript";body="fetch('/guard-worker-started').then(()=>{new WebSocket('ws://127.0.0.1:"+Port+"/guard-worker-ws-ok');new WebSocket('ws://127.0.0.1:"+DeniedPort+"/guard-worker-ws-denied');setTimeout(()=>postMessage('synthetic-loaded'),100);});";}
                if(path=="/guard-shared.js") {type="application/javascript";body="onconnect=e=>{fetch('/guard-shared-started');new WebSocket('ws://127.0.0.1:"+Port+"/guard-shared-ws-ok');new WebSocket('ws://127.0.0.1:"+DeniedPort+"/guard-shared-ws-denied');e.ports[0].postMessage('synthetic-loaded');};";}
                if(path=="/guard-sw.js") {type="application/javascript";body="self.addEventListener('install',e=>e.waitUntil(self.skipWaiting()));self.addEventListener('activate',e=>e.waitUntil(self.clients.claim().then(()=>{fetch('/guard-sw-started');new WebSocket('ws://127.0.0.1:"+Port+"/guard-sw-ws-ok');new WebSocket('ws://127.0.0.1:"+DeniedPort+"/guard-sw-ws-denied');})));";}
                if(path=="/exercise") body="<!doctype html><title>exercise</title><script>"+
                    "fetch('/fetch-ok').catch(()=>{});fetch('"+denied+"/fetch-denied').catch(()=>{});"+
                    "fetch('/post-denied',{method:'POST'}).catch(()=>{});fetch('"+denied+"/post-denied',{method:'POST'}).catch(()=>{});"+
                    "let i=new Image();i.src='/image-ok';let j=new Image();j.src='"+denied+"/image-denied';"+
                    "new Worker('/worker.js');navigator.serviceWorker.register('/sw.js').then(()=>navigator.serviceWorker.ready).then(r=>r.active.postMessage('synthetic-probe')).catch(()=>{});"+
                    "new WebSocket('ws://127.0.0.1:"+Port+"/ws-ok');new WebSocket('ws://127.0.0.1:"+DeniedPort+"/ws-denied');"+
                    "window.open('/popup');</script><iframe src='/frame-child'></iframe><iframe src='"+denied+"/frame-denied'></iframe>";
                byte[] payload=Encoding.UTF8.GetBytes(body);
                byte[] head=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+" Synthetic\r\nContent-Type: "+type+"\r\nAccess-Control-Allow-Origin: *\r\n"+extra+"Content-Length: "+payload.Length+"\r\nConnection: close\r\n\r\n");
                stream.Write(head,0,head.Length);stream.Write(payload,0,payload.Length);
                lock(Writes){if(!Writes.ContainsKey(path))Writes[path]=0;Writes[path]++;}
            } catch(IOException) { /* Client cancellation is expected for denied synthetic requests. */ }
        }
    }
    public void Dispose() {cancellation.Cancel();listener.Stop();}
    string GuardScript() {
        return @"function guardProbe(context){
let result={context:context,http:false,dedicated:false,shared:false,service:false};
const dedicated=new Promise(resolve=>{try{const w=new Worker('/guard-worker.js');w.onerror=e=>{w.terminate();resolve(true);};w.onmessage=e=>{w.terminate();resolve(false);};setTimeout(()=>{w.terminate();resolve(false);},2500);}catch(e){resolve(true);}});
const shared=new Promise(resolve=>{try{const w=new SharedWorker('/guard-shared.js');w.onerror=e=>{w.port.close();resolve(true);};w.port.onmessage=e=>{w.port.close();resolve(false);};w.port.start();setTimeout(()=>{w.port.close();resolve(false);},2500);}catch(e){resolve(true);}});
const service=navigator.serviceWorker.register('/guard-sw.js').then(()=>false,()=>true);
const http=fetch('/guard-http-'+context).then(r=>r.ok,()=>false);
Promise.all([dedicated,shared,service,http]).then(values=>{result.dedicated=values[0];result.shared=values[1];result.service=values[2];result.http=values[3];top.postMessage(result,'__SAFE_PARENT_ORIGIN__');});
}".Replace("'/guard-","'http://127.0.0.1:"+Port+"/guard-").Replace("__SAFE_PARENT_ORIGIN__","http://127.0.0.1:"+Port)+(CalScript??"");
    }
    string GuardContext(string context) {return "<!doctype html><script>"+GuardScript()+"guardProbe('"+context+"');</script>";}
    string GuardMain() {
        var serializer=new JavaScriptSerializer();
        return "<!doctype html><title>guard</title><img src='/guard-original-csp-image-denied'><script>window.guardResults={};window.calResults={};window.addEventListener('message',e=>{if(e.origin===location.origin&&['main','frame','srcdoc','aboutblank','blob'].includes(e.data.context))window.guardResults[e.data.context]=e.data;if(e.origin===location.origin&&['main','frame','srcdoc','aboutblank','blob'].includes(e.data.calContext))window.calResults[e.data.calContext]=e.data;});"+GuardScript()+"guardProbe('main');"+
            "let frame=document.createElement('iframe');frame.src='/guard-frame';document.body?document.body.append(frame):document.documentElement.append(frame);"+
            "let srcdoc=document.createElement('iframe');srcdoc.srcdoc="+serializer.Serialize(GuardContext("srcdoc"))+";document.documentElement.append(srcdoc);"+
            "let blank=document.createElement('iframe');blank.onload=()=>{blank.onload=null;blank.contentDocument.open();blank.contentDocument.write("+serializer.Serialize(GuardContext("aboutblank"))+");blank.contentDocument.close();};blank.src='about:blank';document.documentElement.append(blank);"+
            "let blob=document.createElement('iframe');blob.src=URL.createObjectURL(new Blob(["+serializer.Serialize(GuardContext("blob"))+"],{type:'text/html'}));document.documentElement.append(blob);</script>";
    }
}
class LocalUdpProbe : IDisposable {
    readonly UdpClient receiver;
    volatile bool stop;
    volatile string failure;
    int packets;
    public int Port;
    public int Count {get{return Interlocked.CompareExchange(ref packets,0,0);}}
    public string Failure {get{return failure;}}
    public LocalUdpProbe(bool dedicatedListener=false) {
        receiver=new UdpClient(new IPEndPoint(IPAddress.Loopback,0));receiver.Client.ReceiveTimeout=300;
        Port=((IPEndPoint)receiver.Client.LocalEndPoint).Port;
        if(dedicatedListener)new Thread(Listen){IsBackground=true}.Start();else Task.Run((Action)Listen);
    }
    void Listen() {
        while(!stop) {
            try {IPEndPoint sender=new IPEndPoint(IPAddress.Loopback,0);byte[] packet=receiver.Receive(ref sender);Interlocked.Increment(ref packets);Array.Clear(packet,0,packet.Length);}
            catch(SocketException ex) {if(!stop&&ex.SocketErrorCode!=SocketError.TimedOut){failure=ex.GetType().FullName;break;}}
            catch(ObjectDisposedException ex) {if(!stop)failure=ex.GetType().FullName;break;}
        }
    }
    public void Dispose() {stop=true;receiver.Close();}
}
class LocalTcpCountProbe : IDisposable {
    readonly TcpListener receiver;
    volatile bool stop;
    volatile string failure;
    int connections;
    public int Port;
    public int Count {get{return Interlocked.CompareExchange(ref connections,0,0);}}
    public string Failure {get{return failure;}}
    public LocalTcpCountProbe() {
        receiver=new TcpListener(IPAddress.Loopback,0);receiver.Start();Port=((IPEndPoint)receiver.LocalEndpoint).Port;
        new Thread(Listen){IsBackground=true}.Start();
    }
    void Listen() {
        while(!stop) {
            try {using(var client=receiver.AcceptTcpClient()){Interlocked.Increment(ref connections);/* Never read TURN bytes, first line or authentication bytes. */}}
            catch(SocketException ex){if(!stop)failure=ex.GetType().FullName;break;}
            catch(ObjectDisposedException ex){if(!stop)failure=ex.GetType().FullName;break;}
        }
    }
    public void Dispose(){stop=true;receiver.Stop();}
}
class HttpsFixtureReady {
    public string @event=null,url=null,certificate_sha256_base64=null,certificate_sha256_hex=null;
    public int fixture_version=0,port=0;
}
class LocalHttpsFixture : IDisposable {
    readonly Process process;
    readonly JavaScriptSerializer serializer=new JavaScriptSerializer();
    public HttpsFixtureReady Ready;
    bool stopped;
    int stderrLines;
    readonly TaskCompletionSource<bool> stderrEnd=new TaskCompletionSource<bool>();
    public int StderrLines {get{return Interlocked.CompareExchange(ref stderrLines,0,0);}}
    public bool StderrDrained {get{return stderrEnd.Task.IsCompleted;}}
    public int StopFaultCount=-1;
    public string StopFaultNames="unavailable";
    public LocalHttpsFixture(string runtimeRoot) {
        string workspace=Path.GetFullPath(Path.Combine(Application.StartupPath,"..","..","..",".."));
        string script=Path.Combine(workspace,"verification","https_fixture","fixture.py"),deps=Path.Combine(workspace,"verification",".runtime","transport-deps");
        var info=new ProcessStartInfo(@"E:\conda\envs\basic310\python.exe","\""+script+"\" --runtime-root \""+runtimeRoot+"\" --deps-root \""+deps+"\"");
        info.UseShellExecute=false;info.CreateNoWindow=true;info.WindowStyle=ProcessWindowStyle.Hidden;info.RedirectStandardInput=true;info.RedirectStandardOutput=true;info.RedirectStandardError=true;
        process=Process.Start(info);process.ErrorDataReceived+=(s,a)=>{if(a.Data==null)stderrEnd.TrySetResult(true);else if(a.Data.Length>0)Interlocked.Increment(ref stderrLines);/* Counts only; raw diagnostics never stored or printed. */};process.BeginErrorReadLine();
        try {string line=Line();var shape=serializer.Deserialize<Dictionary<string,object>>(line);if(!shape.ContainsKey("event")||(string)shape["event"]!="ready")throw new InvalidOperationException("https_fixture_not_ready");Ready=serializer.Deserialize<HttpsFixtureReady>(line);if(Ready==null||Ready.@event!="ready"||Ready.fixture_version!=1||Ready.url!="https://127.0.0.1:"+Ready.port+"/query"||Convert.FromBase64String(Ready.certificate_sha256_base64).Length!=32)throw new InvalidOperationException("https_fixture_invalid_ready");}
        catch{Dispose();throw;}
    }
    string Line() {var read=Task.Run(()=>process.StandardOutput.ReadLine());if(!read.Wait(12000))throw new TimeoutException();string value=read.Result;if(value==null||value.Length>8192)throw new InvalidOperationException("https_fixture_control_eof");return value;}
    public Dictionary<string,object> Control(string command) {
        string id=Guid.NewGuid().ToString("N");process.StandardInput.WriteLine(serializer.Serialize(new {command=command,id=id}));process.StandardInput.Flush();
        var value=serializer.Deserialize<Dictionary<string,object>>(Line());string expected=command=="stop"?"stop":"command";if(!value.ContainsKey("id")||(string)value["id"]!=id||!value.ContainsKey("event")||(string)value["event"]!=expected)throw new InvalidOperationException("https_fixture_invalid_control");return value;
    }
    public bool Stop() {
        if(stopped)return process.HasExited&&process.ExitCode==0&&StderrDrained&&StderrLines==0&&StopFaultCount==0;
        var result=Control("stop");stopped=result.ContainsKey("stopped")&&(bool)result["stopped"];
        if(result.ContainsKey("fault_types")&&result["fault_types"] is System.Collections.IEnumerable&&!(result["fault_types"] is string)) {
            var faults=((System.Collections.IEnumerable)result["fault_types"]).Cast<object>().ToArray();StopFaultCount=faults.Length;
            StopFaultNames=String.Join(",",faults.Select(item=>Convert.ToString(item)).Where(item=>System.Text.RegularExpressions.Regex.IsMatch(item,"^[A-Za-z0-9_.]+$")));
        }
        bool exited=process.WaitForExit(12000);bool drained=exited&&stderrEnd.Task.Wait(2000);return stopped&&exited&&process.ExitCode==0&&drained&&StderrLines==0&&StopFaultCount==0;
    }
    public void Dispose(){try{if(!process.HasExited){bool graceful=Stop();if(!graceful&&!process.HasExited){process.Kill();process.WaitForExit(5000);}}}catch{if(!process.HasExited){process.Kill();process.WaitForExit(5000);}}finally{process.Dispose();}}
}
class BrowserProbe : Form {
    readonly string root,mode,evidencePath;
    readonly int allowedPort,deniedPort;
    readonly int udpPort;
    readonly string calContext;
    HttpsFixtureReady https;
    WebView2 web;
    CoreWebView2Environment env;
    Owner owner;
    Evidence evidence=new Evidence();
    HashSet<string> observed=new HashSet<string>();
    HashSet<string> blocked=new HashSet<string>();
    HashSet<string> sourceKinds=new HashSet<string>();
    HashSet<string> calStages=new HashSet<string>();
    Dictionary<string,string> requestMetadata=new Dictionary<string,string>();
    Dictionary<string,ulong> navigationIds=new Dictionary<string,ulong>();
    HashSet<ulong> domIds=new HashSet<ulong>();
    long generation;
    int frameEvents,popups,downloads,externalRejects;
    TaskCompletionSource<bool> processExit=new TaskCompletionSource<bool>();
    TaskCompletionSource<bool> rendererFailure=new TaskCompletionSource<bool>();
    public BrowserProbe(string r,string m,int p,int d,string e,int u=0,string context="main") {
        root=r;mode=m;allowedPort=p;deniedPort=d;evidencePath=e;udpPort=u;calContext=context;
        // Keep the controller logically visible. Minimized/transparent WebViews
        // exhibited lost subresource interception. Opaque host outside screen.
        ShowInTaskbar=false;Opacity=1;WindowState=FormWindowState.Normal;
        StartPosition=FormStartPosition.Manual;Location=new System.Drawing.Point(-30000,-30000);
        Shown+=async (s,a)=> { await Run(); Close(); };
    }
    static async Task<T> Timeout<T>(Task<T> task,int ms) {
        if(await Task.WhenAny(task,Task.Delay(ms))!=task) throw new TimeoutException();
        return await task;
    }
    bool Allowed(string url,string method) {
        if(https!=null&&url==https.url&&(method=="GET"||(mode=="calReference"&&method=="CONNECT")))return true;
        Uri value;
        return Uri.TryCreate(url,UriKind.Absolute,out value)&&value.Scheme=="http"&&value.Host=="127.0.0.1"&&value.Port==allowedPort&&method=="GET";
    }
    bool AllowedFrame(string url) {
        if(Allowed(url,"GET"))return true;
        // Only this synthetic guard experiment constructs these inherited-CSP frames.
        return (mode.StartsWith("guard")||mode.StartsWith("cal"))&&(url=="about:blank"||url=="about:srcdoc"||url.StartsWith("blob:http://127.0.0.1:"+allowedPort+"/",StringComparison.Ordinal));
    }
    string Label(string url) { Uri value;return Uri.TryCreate(url,UriKind.Absolute,out value)?value.AbsolutePath:"invalid"; }
    async Task Navigate(string path,bool expectSuccess) {
        var done=new TaskCompletionSource<bool>();
        ulong expected=0;
        EventHandler<CoreWebView2NavigationStartingEventArgs> starting=(s,a)=> {if(Label(a.Uri)==path)expected=a.NavigationId;};
        EventHandler<CoreWebView2NavigationCompletedEventArgs> handler=(s,a)=> {if(expected!=0&&a.NavigationId==expected)done.TrySetResult(a.IsSuccess);};
        web.CoreWebView2.NavigationStarting+=starting;
        web.CoreWebView2.NavigationCompleted+=handler;
        try {web.CoreWebView2.Navigate("http://127.0.0.1:"+allowedPort+path);bool ok=await DocumentOperation(done.Task,12000);if(expectSuccess&&!ok) throw new InvalidOperationException("navigation_failed");}
        finally {web.CoreWebView2.NavigationCompleted-=handler;web.CoreWebView2.NavigationStarting-=starting;}
    }
    async Task<T> DocumentOperation<T>(Task<T> result,int milliseconds) {
        if(rendererFailure.Task.IsCompleted)throw new NativeBrowserProcessFailureException();
        var finished=await Task.WhenAny(result,rendererFailure.Task,Task.Delay(milliseconds));
        if(rendererFailure.Task.IsCompleted) {
            // Observe a late fault without reading script output after renderer death.
            var observation=result.ContinueWith(t=>{var ignored=t.Exception;},TaskContinuationOptions.OnlyOnFaulted);
            throw new NativeBrowserProcessFailureException();
        }
        if(finished!=result)throw new TimeoutException();
        return await result;
    }
    async Task<bool> BooleanScript(string script) {
        if(rendererFailure.Task.IsCompleted)throw new NativeBrowserProcessFailureException();
        return await DocumentOperation(web.CoreWebView2.ExecuteScriptAsync(script),5000)=="true";
    }
    async Task Run() {
        try {
            // Ownership is acquired before environment/UDF initialization.
            owner=new Owner(root);
            if(mode.StartsWith("cal")&&File.Exists(Path.Combine(root,"https-target.json")))https=new JavaScriptSerializer().Deserialize<HttpsFixtureReady>(File.ReadAllText(Path.Combine(root,"https-target.json")));
            var options=new CoreWebView2EnvironmentOptions();options.AreBrowserExtensionsEnabled=mode.StartsWith("dnr")||mode.StartsWith("guard")||mode.StartsWith("cal");
            string candidate=Environment.GetEnvironmentVariable("DESIGN_RESET_BROWSER_EXECUTABLE_FOLDER");
            string expectedVersion=Environment.GetEnvironmentVariable("DESIGN_RESET_EXPECTED_RUNTIME_VERSION");
            env=await CoreWebView2Environment.CreateAsync(String.IsNullOrEmpty(candidate)?null:candidate,Path.Combine(root,"udf"),options);
            env.BrowserProcessExited+=(s,a)=>processExit.TrySetResult(true);
            web=new WebView2();web.Dock=DockStyle.Fill;Controls.Add(web);
            await web.EnsureCoreWebView2Async(env);
            evidence.runtime=env.BrowserVersionString;
            if(!String.IsNullOrEmpty(candidate)) {
                string actualVersion=evidence.runtime.Split(' ')[0];
                bool selected=actualVersion==expectedVersion;
                using(var browser=Process.GetProcessById((int)web.CoreWebView2.BrowserProcessId)) {
                    string executable=Path.GetFullPath(browser.MainModule.FileName);
                    selected&=new[]{"msedgewebview2.exe","msedge.exe"}.Any(name=>String.Equals(executable,Path.Combine(Path.GetFullPath(candidate),name),StringComparison.OrdinalIgnoreCase));
                }
                evidence.checks.Add(new Check("isolated_runtime_selection",selected,"Actual version and owned browser executable match the explicitly selected workspace candidate. No command line or browser assets read."));
                if(!selected)throw new InvalidOperationException("runtime_selection_mismatch");
            }
            var core=web.CoreWebView2;
            core.Settings.AreDevToolsEnabled=false;
            core.Settings.AreDefaultContextMenusEnabled=false;
            core.NavigationStarting+=(s,a)=> {
                generation++;string label=Label(a.Uri);navigationIds[label]=a.NavigationId;
                if(!Allowed(a.Uri,"GET")) {a.Cancel=true;if(!a.Uri.StartsWith("http://",StringComparison.OrdinalIgnoreCase)&&!a.Uri.StartsWith("https://",StringComparison.OrdinalIgnoreCase)) externalRejects++;}
            };
            core.DOMContentLoaded+=(s,a)=>domIds.Add(a.NavigationId);
            core.FrameCreated+=(s,a)=> {
                a.Frame.NavigationStarting+=(fs,fa)=> {frameEvents++;if(!AllowedFrame(fa.Uri))fa.Cancel=true;};
                a.Frame.FrameCreated+=(fs,fa)=> {fa.Frame.NavigationStarting+=(ns,na)=> {frameEvents++;if(!AllowedFrame(na.Uri))na.Cancel=true;};};
            };
            core.FrameNavigationStarting+=(s,a)=> {if(!AllowedFrame(a.Uri))a.Cancel=true;};
            core.NewWindowRequested+=(s,a)=> {a.Handled=true;popups++;};
            core.DownloadStarting+=(s,a)=> {a.Cancel=true;downloads++;};
            core.LaunchingExternalUriScheme+=(s,a)=> {a.Cancel=true;externalRejects++;};
            core.PermissionRequested+=(s,a)=>a.State=CoreWebView2PermissionState.Deny;
            if(https!=null)core.ServerCertificateErrorDetected+=(s,a)=>{
                a.Action=CoreWebView2ServerCertificateErrorAction.Cancel;
                if(a.RequestUri!=https.url)return;
                byte[] der=null,digest=null;
                try {string pem=a.ServerCertificate.ToPemEncoding();der=Convert.FromBase64String(pem.Replace("-----BEGIN CERTIFICATE-----","").Replace("-----END CERTIFICATE-----","").Replace("\r","").Replace("\n",""));using(var sha=SHA256.Create())digest=sha.ComputeHash(der);if(Convert.ToBase64String(digest)==https.certificate_sha256_base64)a.Action=CoreWebView2ServerCertificateErrorAction.AlwaysAllow;}
                catch(FormatException){}finally{if(der!=null)Array.Clear(der,0,der.Length);if(digest!=null)Array.Clear(digest,0,digest.Length);}
            };
            if(mode.StartsWith("cal"))core.ProcessFailed+=(s,a)=> {
                evidence.checks.Add(new Check("CAL_native_process_failure_"+mode,false,"ProcessFailed kind="+a.ProcessFailedKind+"; reason="+a.Reason+"; exitCode="+a.ExitCode+"; exitHex="+unchecked((uint)a.ExitCode).ToString("X8")+". No dumps, diagnostic files or command lines read."));
                rendererFailure.TrySetResult(true);
            };
            if(mode.StartsWith("cal"))core.WebMessageReceived+=(s,a)=>{try{string value=a.TryGetWebMessageAsString();if(System.Text.RegularExpressions.Regex.IsMatch(value,"^syntheticCalStage:(main|frame|srcdoc|aboutblank|blob):(stun|turn|wt):(beforeConstructor|afterConstructor|afterChannel|beforeOffer|afterOffer|done)$"))calStages.Add(value.Substring(18));}catch(ArgumentException){}};
            core.AddWebResourceRequestedFilter("*",CoreWebView2WebResourceContext.All,CoreWebView2WebResourceRequestSourceKinds.All);
            core.WebResourceRequested+=(s,a)=> {
                // Do not read Request.Headers, Request.Content, cookies, tokens, or browser asset files.
                string label=Label(a.Request.Uri);observed.Add(label);sourceKinds.Add(a.RequestedSourceKind.ToString());
                if(new[]{"/fetch-ok","/fetch-denied","/image-ok","/image-denied","/post-denied","/worker-ok","/worker-denied","/sw-ok","/sw-denied","/ws-ok","/ws-denied","/exercise","/frame-child"}.Contains(label)) requestMetadata[label]=a.Request.Method+"/"+a.ResourceContext+"/"+a.RequestedSourceKind;
                if(!Allowed(a.Request.Uri,a.Request.Method)) {blocked.Add(label);a.Response=env.CreateWebResourceResponse(new MemoryStream(new byte[0]),403,"Blocked","Content-Type: text/plain");}
            };
            if(mode=="cdp") {
                await Timeout(core.CallDevToolsProtocolMethodAsync("Network.enable","{}"),5000);
                string parameters=new JavaScriptSerializer().Serialize(new {urls=new[]{"*://127.0.0.1:"+deniedPort+"/*","ws://*","wss://*"}});
                await Timeout(core.CallDevToolsProtocolMethodAsync("Network.setBlockedURLs",parameters),5000);
                evidence.checks.Add(new Check("CDP_candidate_configured",true,"Network.enable + Network.setBlockedURLs installed before navigation; no Network events/headers/bodies subscribed or read."));
            }
            if(mode.StartsWith("dnr")||mode.StartsWith("guard")||mode.StartsWith("cal")) {
                if(mode=="dnr"||mode=="guard"||mode=="guardReference"||(mode.StartsWith("cal")&&!mode.EndsWith("Restart"))) {
                    var extension=await Timeout(core.Profile.AddBrowserExtensionAsync(Path.Combine(root,"static-policy")),7000);
                    if(!extension.IsEnabled)throw new InvalidOperationException("extension_not_enabled");
                    File.WriteAllText(Path.Combine(root,"policy-id"),extension.Id);
                }
                var installed=await core.Profile.GetBrowserExtensionsAsync();
                string policyId=File.ReadAllText(Path.Combine(root,"policy-id"));
                bool ready=installed.Any(item=>item.Id==policyId&&item.IsEnabled);
                evidence.checks.Add(new Check("DNR_policy_ready_"+mode,ready,"Registered static policy enabled before navigation; extension inventory count="+installed.Count+". No background/content scripts or webRequest. Guard variant grants only loopback HTTP host permission for static response-header append."));
                if(!ready)throw new InvalidOperationException("extension_not_ready");
            }
            await Navigate("/storage",true);
            if(mode=="setA") {
                bool ok=await BooleanScript("(()=>{localStorage.setItem('syntheticMarker','partition-A');return localStorage.getItem('syntheticMarker')==='partition-A';})()");
                evidence.checks.Add(new Check("synthetic_storage_A_set",ok,"Only synthetic marker; returned safe boolean."));
                await RunBehavior();
            } else if(mode=="checkB") {
                bool ok=await BooleanScript("localStorage.getItem('syntheticMarker')===null");
                evidence.checks.Add(new Check("independent_UDF_B",ok,"Separate UDF does not observe A synthetic marker."));
            } else if(mode=="checkA") {
                bool ok=await BooleanScript("localStorage.getItem('syntheticMarker')==='partition-A'");
                evidence.checks.Add(new Check("cross_process_UDF_A_reuse",ok,"Reopened A after prior process exited; synthetic marker persists."));
            } else if(mode=="cdp"||mode.StartsWith("dnr")) {
                await Navigate("/exercise",true);await Task.Delay(3500);
                await BooleanScript("(()=>{let f=document.createElement('iframe');f.src='/cdp-frame';document.body.append(f);return true;})()");
                await Task.Delay(1500);
                evidence.checks.Add(new Check((mode=="cdp"?"CDP":"DNR_"+mode)+"_candidate_requests_exercised",true,"Main/frame requests, dedicated worker and service worker exercised on loopback. Network receipts determine actual blocking."));
            } else if(mode.StartsWith("calMinimal")||mode.StartsWith("calDirect")) {
                if(mode.Contains("Navigate")){await Navigate("/landing",true);evidence.checks.Add(new Check("CAL_minimal_second_navigation_"+mode,true,"Inert /storage to inert /landing completed; both responses carry the same CAL when guarded. No frames/workers/WT/previous RTC."));}
                await RunMinimalRtc();
            } else if(mode.StartsWith("cal")) {
                if(https!=null) {await RunHttpsCal();} else {
                try {await Navigate("/guard",true);evidence.checks.Add(new Check("CAL_normal_second_navigation_"+mode,true,"Same-origin /storage to /guard navigation completed."));}
                catch(TimeoutException) {evidence.checks.Add(new Check("CAL_normal_second_navigation_"+mode,false,"Navigation timeout; NavigationStarting /guard seen="+navigationIds.ContainsKey("/guard")+"; DOMContentLoaded /guard seen="+(navigationIds.ContainsKey("/guard")&&domIds.Contains(navigationIds["/guard"]))+"; HTTP event seen="+observed.Contains("/guard")+". Continuing only for diagnostic counts; timeout remains failure."));}
                await Task.Delay(300);
                int contextIndex=Array.IndexOf(new[]{"frame","srcdoc","aboutblank","blob"},calContext);
                string target=contextIndex<0?"window":"document.querySelectorAll('iframe')["+contextIndex+"].contentWindow";
                await BooleanScript("(()=>{"+target+".calProbe('"+calContext+"');return true;})()");
                bool complete=false;
                for(int i=0;i<55;i++){if(await BooleanScript("Object.keys(window.guardResults||{}).length===5&&Boolean(window.calResults['"+calContext+"'])")){complete=true;break;}await Task.Delay(100);}
                evidence.checks.Add(new Check("CAL_contexts_"+mode,complete,"Five native contexts independently report worker/HTTP; selected network context="+calContext+". Each network context has an independent browser child to isolate native stalls."));
                foreach(string context in new[]{"main","frame","srcdoc","aboutblank","blob"}) {
                    evidence.checks.Add(new Check("CAL_http_"+mode+"_"+context,await BooleanScript("Boolean(window.guardResults['"+context+"']&&window.guardResults['"+context+"'].http)"),"Allowed GET is positive in each native context."));
                    foreach(string kind in new[]{"dedicated","shared","service"})evidence.checks.Add(new Check("CAL_worker_guard_"+mode+"_"+context+"_"+kind,await BooleanScript("Boolean(window.guardResults['"+context+"'])&&window.guardResults['"+context+"']."+kind+"===true"),"Native worker attempt rejected under appended worker-src none."));
                    foreach(string channel in context==calContext?new[]{"stun","turn","wt"}:new string[0]) {
                        string result="window.calResults['"+context+"']&&window.calResults['"+context+"']."+channel;
                        bool attempted=await BooleanScript("Boolean("+result+")&&window.calResults['"+context+"']."+channel+".attempted===true&&window.calResults['"+context+"']."+channel+".done===true");
                        bool constructed=await BooleanScript("Boolean("+result+")&&window.calResults['"+context+"']."+channel+".constructed===true");
                        bool offer=channel=="wt"?false:await BooleanScript("Boolean("+result+")&&window.calResults['"+context+"']."+channel+".offer===true");
                        evidence.checks.Add(new Check("CAL_attempt_"+mode+"_"+context+"_"+channel,attempted,"Native attempt/done="+attempted+"; constructed="+constructed+"; RTC offer/local-description="+offer+". Actual independent receiver count is required, API presence is insufficient."));
                    }
                }
                await BooleanScript("(()=>{window.calRegistrationDone=false;navigator.serviceWorker.getRegistrations().then(r=>{window.calRegistrationZero=r.length===0;window.calRegistrationDone=true;});return true;})()");
                for(int i=0;i<20;i++){if(await BooleanScript("window.calRegistrationDone===true"))break;await Task.Delay(100);}
                evidence.checks.Add(new Check("CAL_no_SW_registrations_"+mode,await BooleanScript("window.calRegistrationDone===true&&window.calRegistrationZero===true"),"Zero-registration boolean only; browser asset files not read."));
                }
            } else if(mode.StartsWith("guard")) {
                await Navigate("/guard",true);
                bool complete=false;
                for(int i=0;i<35;i++) {if(await BooleanScript("Object.keys(window.guardResults||{}).length===5")){complete=true;break;}await Task.Delay(100);}
                evidence.checks.Add(new Check("WorkerGuard_contexts_"+mode,complete,"Five synthetic contexts must report attempted dedicated/shared/service-worker construction plus HTTP positive."));
                bool expectBlocked=mode!="guardReference";
                foreach(string context in new[]{"main","frame","srcdoc","aboutblank","blob"}) {
                    bool http=await BooleanScript("Boolean(window.guardResults['"+context+"']&&window.guardResults['"+context+"'].http)");
                    evidence.checks.Add(new Check("WorkerGuard_http_"+mode+"_"+context,http,"Normal allowed GET remains functional in this context."));
                    foreach(string kind in new[]{"dedicated","shared","service"}) {
                        if(mode=="guardReference"&&kind=="service"&&context!="main"&&context!="frame") {
                            bool rejected=await BooleanScript("Boolean(window.guardResults['"+context+"'])&&window.guardResults['"+context+"'].service===true");
                            evidence.checks.Add(new Check("WorkerGuard_reference_service_surface_"+context,"info","Unguarded native registration rejected="+rejected+"; inherited/non-HTTP document may already disallow service-worker registration."));
                            continue;
                        }
                        bool matches=await BooleanScript("Boolean(window.guardResults['"+context+"'])&&window.guardResults['"+context+"']."+kind+"==="+(expectBlocked?"true":"false"));
                        evidence.checks.Add(new Check("WorkerGuard_"+mode+"_"+context+"_"+kind,matches,expectBlocked?"Native worker construction/registration rejected; no JS monkeypatch.":"Unguarded control permits native worker construction/registration."));
                    }
                }
                await BooleanScript("(()=>{window.guardRegistrationChecked=false;navigator.serviceWorker.getRegistrations().then(r=>{window.guardNoRegistrations=r.length===0;window.guardRegistrationChecked=true;});return true;})()");
                for(int i=0;i<20;i++) {if(await BooleanScript("window.guardRegistrationChecked===true"))break;await Task.Delay(100);}
                bool registrationMatches=await BooleanScript("window.guardRegistrationChecked===true&&window.guardNoRegistrations==="+(expectBlocked?"true":"false"));
                evidence.checks.Add(new Check("WorkerGuard_registrations_"+mode,registrationMatches,"Browser script returns only safe zero-registration boolean; host does not read browser asset files."));
                bool webTransport=await BooleanScript("typeof WebTransport==='function'"),webRtc=await BooleanScript("typeof RTCPeerConnection==='function'");
                evidence.checks.Add(new Check("WorkerGuard_API_surface_"+mode,"info","WebTransport constructor present="+webTransport+"; RTCPeerConnection present="+webRtc+". WebTransport is not connected; RTC execution/UDP receipts have separate checks."));
                if(udpPort>0&&webRtc) {
                    await BooleanScript("(()=>{window.rtcProbeDone=false;window.rtcConstructed=false;window.rtcAttempted=false;window.rtcProbeFailed=false;try{let pc=new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:"+udpPort+"'}]});window.rtcConstructed=true;pc.createDataChannel('synthetic');pc.createOffer().then(d=>pc.setLocalDescription(d)).then(()=>{window.rtcAttempted=true;setTimeout(()=>{pc.close();window.rtcProbeDone=true;},2200);}).catch(()=>{pc.close();window.rtcProbeFailed=true;window.rtcProbeDone=true;});}catch(e){window.rtcProbeFailed=true;window.rtcProbeDone=true;}return true;})()");
                    bool done=false;for(int i=0;i<35;i++){if(await BooleanScript("window.rtcProbeDone===true")){done=true;break;}await Task.Delay(100);}
                    bool constructed=await BooleanScript("window.rtcConstructed===true"),attempted=await BooleanScript("window.rtcAttempted===true"),failed=await BooleanScript("window.rtcProbeFailed===true");
                    evidence.checks.Add(new Check("WebRTC_probe_execution_"+mode,done&&constructed&&attempted&&!failed,"Constructed="+constructed+"; offer/local-description attempted="+attempted+"; closed/done="+done+"; error="+failed+". STUN target only loopback; receipt count is reported by UDP receiver."));
                } else evidence.checks.Add(new Check("WebRTC_probe_execution_"+mode,"not_run","No supported constructor/UDP probe was available; absence of traffic does not prove blocking."));
                await Task.Delay(300);
            } else throw new InvalidOperationException("mode_invalid");
        } catch(Exception ex) {evidence.checks.Add(new Check("browser_probe_exception",false,ex.GetType().FullName));}
        {
            if(mode.StartsWith("cal"))evidence.checks.Add(new Check("CAL_native_stages_"+mode,"info",String.Join(",",calStages.OrderBy(item=>item))));
            try {
                if(web!=null) {
                    web.Dispose();web=null;
                    bool drained=await Timeout(processExit.Task,12000);
                    evidence.checks.Add(new Check("close_and_drain_"+mode,drained,"Dispose followed by Environment.BrowserProcessExited; no deletion before exit event."));
                }
            } catch(Exception ex) {evidence.deletePending=true;evidence.checks.Add(new Check("close_and_drain_"+mode,false,ex.GetType().FullName));}
            if(owner!=null)owner.Dispose();
            Program.Write(evidencePath,evidence);
        }
    }
    async Task RunBehavior() {
        await Navigate("/redirect",true);
        evidence.checks.Add(new Check("redirect_navigation_id",navigationIds.ContainsKey("/redirect")&&navigationIds.ContainsKey("/landing")&&navigationIds["/redirect"]==navigationIds["/landing"]&&domIds.Contains(navigationIds["/landing"]),"Redirect hops share NavigationId; DOM ready correlates with final main document."));
        await Navigate("/redirect-denied",false);
        evidence.checks.Add(new Check("redirect_each_hop_policy",navigationIds.ContainsKey("/redirect-target"),"Denied redirect target reached NavigationStarting and was canceled before network."));
        await Navigate("/frame",true);await Task.Delay(350);
        evidence.checks.Add(new Check("frame_separate_events",frameEvents>0,"Frame navigation tracked separately from main-document generation."));
        await Navigate("/storage",true);
        long old=generation;
        Task<string> pending=coreScript("(()=>{const start=Date.now();while(Date.now()-start<250){};return true;})()");
        await Navigate("/new-document",true);
        string delayed=await Timeout(pending,5000);
        bool discard=old!=generation;
        evidence.checks.Add(new Check("late_script_result_guard",discard,"Actual ExecuteScriptAsync result pending across navigation is discarded by host generation guard. This does not prove atomic secret targeting."));
        await Navigate("/exercise",true);await Task.Delay(4000);
        evidence.checks.Add(new Check("safe_request_metadata","info",String.Join("; ",requestMetadata.Select(item=>item.Key+"="+item.Value))));
        evidence.checks.Add(new Check("filter_document",observed.Contains("/exercise"),"Three-argument All-source filter observed main document."));
        evidence.checks.Add(new Check("filter_frame",observed.Contains("/frame-child"),"All-source filter observed iframe document."));
        foreach(string category in new[]{"fetch","image","worker","sw"}) {
            evidence.checks.Add(new Check("request_"+category,observed.Contains("/"+category+"-ok")&&blocked.Contains("/"+category+"-denied"),"Allowed synthetic request observed; denied-origin request intercepted using URI/method/context/source only."));
        }
        evidence.checks.Add(new Check("POST_event_interception",blocked.Contains("/post-denied"),"At least one POST event canceled; server-side checks separately determine actual full coverage. No header/body inspection."));
        evidence.checks.Add(new Check("request_WebSocket",observed.Contains("/ws-denied")&&blocked.Contains("/ws-denied"),"WebSocket must be intercepted; ws scheme may bypass WebResourceRequested despite Websocket context enum."));
        evidence.checks.Add(new Check("source_kind_ServiceWorker",sourceKinds.Contains("ServiceWorker"),"Service worker request source must be observed by All-source overload."));
        evidence.checks.Add(new Check("popup_handled",popups>0,"Every NewWindowRequested marked Handled; no popup WebView created."));
        await Navigate("/download",false);await Task.Delay(300);
        evidence.checks.Add(new Check("download_cancel",downloads>0,"Every DownloadStarting canceled."));
        core.Navigate("mailto:synthetic@example.invalid");await Task.Delay(400);
        evidence.checks.Add(new Check("external_scheme_reject",externalRejects>0,"Non-HTTP navigation canceled before OS protocol handler launch."));
    }
    async Task RunHttpsCal() {
        await Navigate("/guard",true);
        evidence.checks.Add(new Check("CAL_HTTPS_normal_navigation_"+mode,true,"Same-origin /storage to /guard completed before HTTPS-only challenge; no RTC constructor in this child."));
        int contextIndex=Array.IndexOf(new[]{"frame","srcdoc","aboutblank","blob"},calContext);
        string target=contextIndex<0?"window":"document.querySelectorAll('iframe')["+contextIndex+"].contentWindow";
        await Task.Delay(300);
        await BooleanScript("(()=>{"+target+".calHttpsProbe('"+calContext+"');return true;})()");
        bool done=false;for(int i=0;i<60;i++){if(await BooleanScript("Boolean(window.calResults['"+calContext+"'])&&window.calResults['"+calContext+"'].done===true")){done=true;break;}await Task.Delay(100);}
        string result="window.calResults['"+calContext+"']";
        bool http=await BooleanScript("Boolean("+result+")&&"+result+".http===true");
        bool attempted=await BooleanScript("Boolean("+result+")&&"+result+".attempted===true&&"+result+".constructed===true");
        bool ready=await BooleanScript("Boolean("+result+")&&"+result+".ready===true"),echo=await BooleanScript("Boolean("+result+")&&"+result+".echo===true"),rejected=await BooleanScript("Boolean("+result+")&&"+result+".rejected===true");
        evidence.checks.Add(new Check("CAL_HTTPS_GET_"+mode+"_"+calContext,http,"Exact allowlisted HTTPS /query GET completed under exact loopback certificate SHA256 match; no global trust changes or response-body reads."));
        evidence.checks.Add(new Check("CAL_HTTPS_WT_attempt_"+mode+"_"+calContext,done&&attempted,"WebTransport constructed/attempted="+attempted+"; done="+done+"; ready="+ready+"; fixed synthetic datagram echo="+echo+"; rejected="+rejected+". Endpoint URL identical to allowed HTTPS GET."));
        evidence.checks.Add(new Check("CAL_HTTPS_WT_outcome_"+mode+"_"+calContext,mode=="calReference"?ready&&echo:!ready&&!echo&&rejected,mode=="calReference"?"DNR CONNECT-allow reference requires ready and actual fixed synthetic echo.":"CAL allows same HTTPS URL; higher-priority method CONNECT block must reject WebTransport before network. Native receipt counters separately required."));
    }
    async Task RunMinimalRtc() {
        await BooleanScript("(()=>{window.calDone=false;window.calConstructed=false;window.calOffer=false;window.calRejected=false;try{let pc=new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:"+udpPort+"'}]});window.calConstructed=true;pc.createDataChannel('synthetic');pc.createOffer().then(d=>pc.setLocalDescription(d)).then(()=>{window.calOffer=true;setTimeout(()=>{pc.close();window.calDone=true;},2200);}).catch(()=>{pc.close();window.calRejected=true;window.calDone=true;});}catch(e){window.calRejected=true;window.calDone=true;}return true;})()");
        bool done=false;for(int i=0;i<35;i++){if(await BooleanScript("window.calDone===true")){done=true;break;}await Task.Delay(100);}
        bool constructed=await BooleanScript("window.calConstructed===true"),offer=await BooleanScript("window.calOffer===true"),rejected=await BooleanScript("window.calRejected===true");
        evidence.checks.Add(new Check("CAL_minimal_RTC_"+mode,done&&(!mode.EndsWith("Reference")||(constructed&&offer&&!rejected)),"Single native STUN RTC attempt in "+(mode.Contains("Navigate")?"/landing":"/storage")+"; done="+done+"; constructed="+constructed+"; offer/local-description="+offer+"; native rejection="+rejected+". No workers, child frames, second RTC or WebTransport constructors executed."));
    }
    CoreWebView2 core {get{return web.CoreWebView2;}}
    Task<string> coreScript(string script) {return core.ExecuteScriptAsync(script);}
    public bool Failed {get{return evidence.checks.Any(c=>c.status=="fail");}}
}
class Program {
    static JavaScriptSerializer json=new JavaScriptSerializer();
    public static void Write(string path,Evidence e) {File.WriteAllText(path,json.Serialize(e),new UTF8Encoding(false));}
    static void RecordRuntime(Evidence evidence,string runtime) {
        if(String.IsNullOrEmpty(runtime))evidence.checks.Add(new Check("runtime_identity_missing",false,"Browser child did not establish a runtime identity."));
        else if(evidence.runtime==null)evidence.runtime=runtime;
        else if(evidence.runtime!=runtime)evidence.checks.Add(new Check("runtime_changed_within_suite",false,"Browser children used different runtime versions; rerun after the runtime update completes."));
    }
    static Process Child(string args) {
        var info=new ProcessStartInfo(Application.ExecutablePath,args);
        info.UseShellExecute=false;info.CreateNoWindow=true;info.WindowStyle=ProcessWindowStyle.Hidden;
        return Process.Start(info);
    }
    static string Quote(string arg) {return "\""+arg+"\"";}
    static void Wait(Process p,int ms) {if(!p.WaitForExit(ms)){p.Kill();throw new TimeoutException();}}
    [STAThread] static int Main(string[] args) {
        if(args.Length==0)return 3;
        if(args[0]=="own") {
            try {using(var owner=new Owner(args[1])) {File.WriteAllText(args[2],"owned-before-assets");Thread.Sleep(60000);}return 0;}
            catch(IOException){return 23;}
        }
        if(args[0]=="try-own") {try {using(var owner=new Owner(args[1])){} return 0;}catch(IOException){return 23;}}
        if(args[0]=="browser") {
            Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
            var probe=new BrowserProbe(args[1],args[2],Int32.Parse(args[3]),Int32.Parse(args[4]),args[5],args.Length>6?Int32.Parse(args[6]):0,args.Length>7?args[7]:"main");
            Application.Run(probe);return probe.Failed?1:0;
        }
        if(args[0]=="suite")return Suite(args[1],args[2]);
        if(args[0]=="dnr-suite")return Suite(args[1],args[2],true);
        if(args[0]=="worker-guard-suite")return GuardSuite(args[1],args[2]);
        if(args[0]=="connection-allowlist-suite")return ConnectionAllowlistSuite(args[1],args[2]);
        if(args[0]=="connection-allowlist-minimal-suite")return MinimalCalSuite(args[1],args[2]);
        if(args[0]=="connection-allowlist-minimal-navigation-suite")return MinimalCalSuite(args[1],args[2],true);
        if(args[0]=="connection-allowlist-https-suite")return ConnectionAllowlistSuite(args[1],args[2],true);
        if(args[0]=="cal-cleanup-unopened")return CleanupUnopenedCal(args[1],args[2]);
        return 3;
    }
    static int Suite(string root,string output,bool onlyDnr=false) {
        var evidence=new Evidence();
        try {
            using(var overall=new Owner(root)) {
                if(!onlyDnr) {
                string ownerPath=Path.Combine(root,"owner-test");Directory.CreateDirectory(ownerPath);
                string ready=Path.Combine(root,"owner-ready");
                var holder=Child("own "+Quote(ownerPath)+" "+Quote(ready));
                try {
                    Stopwatch watch=Stopwatch.StartNew();while(!File.Exists(ready)&&watch.ElapsedMilliseconds<6000)Thread.Sleep(50);
                    if(!File.Exists(ready))throw new TimeoutException();
                    var duplicate=Child("try-own "+Quote(Path.Combine(ownerPath,".").ToUpperInvariant()));Wait(duplicate,6000);
                    evidence.checks.Add(new Check("process_ownership_before_assets",duplicate.ExitCode==23,"Second process rejected on actual file handle before any browser/database asset opened."));
                    evidence.checks.Add(new Check("path_canonical_equivalence",String.Equals(Owner.Resolve(ownerPath),Owner.Resolve(Path.Combine(ownerPath,".").ToUpperInvariant()),StringComparison.OrdinalIgnoreCase),"GetFinalPathNameByHandle agrees for case/dot path aliases."));
                } finally {if(!holder.HasExited)holder.Kill();Wait(holder,6000);holder.Dispose();}
                var restarted=Child("try-own "+Quote(ownerPath));Wait(restarted,6000);
                evidence.checks.Add(new Check("crash_release_and_restart",restarted.ExitCode==0,"Killed owner process; fresh process reacquired OS file handle."));
                ReparseCheck(root,evidence);
                Dpapi(evidence);
                using(var allowed=new LocalServer())using(var denied=new LocalServer()) {
                    allowed.DeniedPort=denied.Port;denied.DeniedPort=denied.Port;
                    string a=Path.Combine(root,"partition-A"),b=Path.Combine(root,"partition-B");Directory.CreateDirectory(a);Directory.CreateDirectory(b);
                    foreach(string mode in new[]{"setA","checkB","checkA"}) {
                        string path=mode=="checkB"?b:a;
                        string result=Path.Combine(root,mode+".json");
                        var child=Child("browser "+Quote(path)+" "+mode+" "+allowed.Port+" "+denied.Port+" "+Quote(result));Wait(child,45000);
                        if(!File.Exists(result))throw new IOException("child_evidence_missing");
                        var sub=json.Deserialize<Evidence>(File.ReadAllText(result));evidence.runtime=sub.runtime;
                        evidence.checks.AddRange(sub.checks);evidence.deletePending|=sub.deletePending;
                    }
                    foreach(string category in new[]{"fetch","image","frame","worker","sw","post","redirect"}) {
                        string label=category=="redirect"?"/redirect-target":"/"+category+"-denied";
                        evidence.checks.Add(new Check("network_denied_"+category,denied.Count(label)==0,"Denied server received "+denied.Count(label)+" synthetic requests."));
                    }
                    evidence.checks.Add(new Check("network_POST_allowed_origin",allowed.Count("/post-denied")==0,"POST on allowed origin received "+allowed.Count("/post-denied")+" requests."));
                    evidence.checks.Add(new Check("network_denied_WebSocket",denied.Count("/ws-denied")==0,"Denied server received "+denied.Count("/ws-denied")+" synthetic WebSocket handshakes; any hit is a platform policy gap."));
                    foreach(string category in new[]{"fetch","image","frame","worker","sw"}) {
                        string label=category=="frame"?"/frame-child":"/"+category+"-ok";
                        evidence.checks.Add(new Check("network_allowed_"+category,allowed.Count(label)>0,"Allowed server received "+allowed.Count(label)+" synthetic requests; verifies execution."));
                    }
                    evidence.checks.Add(new Check("network_popup_reject",allowed.Count("/popup")==0,"Handled popup did not request target."));
                }
                using(var cdpAllowed=new LocalServer())using(var cdpDenied=new LocalServer()) {
                    cdpAllowed.DeniedPort=cdpDenied.Port;cdpDenied.DeniedPort=cdpDenied.Port;
                    string c=Path.Combine(root,"partition-CDP");Directory.CreateDirectory(c);
                    string result=Path.Combine(root,"cdp.json");
                    var child=Child("browser "+Quote(c)+" cdp "+cdpAllowed.Port+" "+cdpDenied.Port+" "+Quote(result));Wait(child,45000);
                    var sub=json.Deserialize<Evidence>(File.ReadAllText(result));evidence.checks.AddRange(sub.checks);evidence.deletePending|=sub.deletePending;
                    foreach(string path in new[]{"/fetch-denied","/image-denied","/post-denied","/worker-denied","/sw-denied","/ws-denied","/cdp-frame-fetch-denied","/cdp-frame-image-denied","/frame-ws-denied","/worker-ws-denied","/sw-ws-denied"}) {
                        evidence.checks.Add(new Check("CDP_network_denied"+path,cdpDenied.Count(path)==0,"Denied server received "+cdpDenied.Count(path)+" synthetic requests/handshakes."));
                    }
                    foreach(string category in new[]{"fetch","image","worker","sw"})evidence.checks.Add(new Check("CDP_network_allowed_"+category,cdpAllowed.Count("/"+category+"-ok")>0,"Allowed synthetic source executes under candidate policy."));
                    evidence.checks.Add(new Check("CDP_service_worker_WebSocket_attempt",cdpAllowed.Count("/sw-ws-supported")>0,"Synthetic service worker reports WebSocket constructor availability before attempting local sockets."));
                    foreach(string path in new[]{"/ws-ok","/frame-ws-ok","/worker-ws-ok","/sw-ws-ok"}) evidence.checks.Add(new Check("CDP_deny_all_sockets"+path,cdpAllowed.Count(path)==0,"Candidate intends to reject all ws/wss including allowlisted origin; observed "+cdpAllowed.Count(path)+" handshakes."));
                    if(!sub.deletePending)SafeDelete(root,c);
                }
                }
                var dnrEvidence=new Evidence();
                dnrEvidence.command="powershell -NoProfile -ExecutionPolicy Bypass -File verification/windows/run.ps1 -Variant dnr -EvidencePath <chosen-evidence-file>";
                using(var dnrAllowed=new LocalServer())using(var dnrDenied=new LocalServer()) {
                    dnrAllowed.DeniedPort=dnrDenied.Port;dnrDenied.DeniedPort=dnrDenied.Port;
                    string p=Path.Combine(root,"partition-DNR");Directory.CreateDirectory(p);
                    MakeDnrExtension(p,dnrAllowed.Port);
                    foreach(string mode in new[]{"dnr","dnrRestart"}) {
                        dnrAllowed.Clear();dnrDenied.Clear();
                        string result=Path.Combine(root,mode+".json");
                        var child=Child("browser "+Quote(p)+" "+mode+" "+dnrAllowed.Port+" "+dnrDenied.Port+" "+Quote(result));Wait(child,45000);
                        var sub=json.Deserialize<Evidence>(File.ReadAllText(result));dnrEvidence.runtime=sub.runtime;dnrEvidence.checks.AddRange(sub.checks);dnrEvidence.deletePending|=sub.deletePending;
                        foreach(string path in new[]{"/fetch-denied","/image-denied","/post-denied","/worker-denied","/sw-denied","/ws-denied","/cdp-frame-fetch-denied","/cdp-frame-image-denied","/frame-ws-denied","/worker-ws-denied","/sw-ws-denied"})
                            dnrEvidence.checks.Add(new Check("DNR_"+mode+"_denied"+path,dnrDenied.Count(path)==0,"Denied server received "+dnrDenied.Count(path)+" synthetic requests/handshakes."));
                        dnrEvidence.checks.Add(new Check("DNR_"+mode+"_POST_allowed_origin",dnrAllowed.Count("/post-denied")==0,"GET-only allowance rejects POST even at allowed origin."));
                        foreach(string category in new[]{"fetch","image","worker","sw"})dnrEvidence.checks.Add(new Check("DNR_"+mode+"_allowed_"+category,dnrAllowed.Count("/"+category+"-ok")>0,"Allowed synthetic source executes under static policy."));
                        dnrEvidence.checks.Add(new Check("DNR_"+mode+"_SW_socket_attempt",dnrAllowed.Count("/sw-ws-supported")>0,"Synthetic SW confirms WebSocket constructor availability before attempting sockets."));
                        foreach(string path in new[]{"/ws-ok","/frame-ws-ok","/worker-ws-ok","/sw-ws-ok"})dnrEvidence.checks.Add(new Check("DNR_"+mode+"_deny_all_sockets"+path,dnrAllowed.Count(path)==0,"All ws/wss intended blocked; received "+dnrAllowed.Count(path)+" synthetic handshakes."));
                    }
                    if(!dnrEvidence.deletePending) {SafeDelete(root,p);dnrEvidence.checks.Add(new Check("DNR_UDF_cleanup",!Directory.Exists(p),"Both runs drained before in-root physical deletion."));}
                }
                if(onlyDnr) {Write(output,dnrEvidence);return dnrEvidence.checks.Any(item=>item.status=="fail")?1:0;}
                string dnrName=Path.GetFileName(output)=="evidence.json"?"evidence-dnr.json":Path.GetFileNameWithoutExtension(output)+"-dnr.json";
                Write(Path.Combine(Path.GetDirectoryName(output),dnrName),dnrEvidence);
                evidence.checks.AddRange(dnrEvidence.checks);evidence.deletePending|=dnrEvidence.deletePending;
                if(!evidence.deletePending) {
                    string state=Path.Combine(root,"cleanup-state.json");
                    string held=Path.Combine(root,"partition-A",".synthetic-delete-probe");
                    // Persistent pending state is recorded before attempting cleanup.
                    File.WriteAllText(state,"{\"partitionA\":\"deletePending\"}");
                    bool refused=false;
                    using(var heldFile=new FileStream(held,FileMode.Create,FileAccess.ReadWrite,FileShare.None)) {
                        try {SafeDelete(root,Path.Combine(root,"partition-A"));}
                        catch(IOException) {refused=true;}
                        evidence.checks.Add(new Check("cleanup_failure_retains_pending",refused&&Directory.Exists(Path.Combine(root,"partition-A"))&&File.ReadAllText(state).Contains("deletePending"),"Deliberately held nonsecret sentinel prevents physical cleanup; durable deletePending remains and no success reported."));
                    }
                    SafeDelete(root,Path.Combine(root,"partition-A"));SafeDelete(root,Path.Combine(root,"partition-B"));
                    File.WriteAllText(state,"{\"partitionA\":\"removed\",\"partitionB\":\"removed\"}");
                    evidence.checks.Add(new Check("UDF_physical_cleanup",!Directory.Exists(Path.Combine(root,"partition-A"))&&!Directory.Exists(Path.Combine(root,"partition-B")),"BrowserProcessExited precedes deletion; verified exact in-root paths and absent directories."));
                } else evidence.checks.Add(new Check("UDF_physical_cleanup",false,"deletePending retained; drain failed, no cleanup success reported."));
            }
        } catch(Exception ex) {evidence.deletePending=true;evidence.checks.Add(new Check("suite_exception",false,ex.GetType().FullName+"; code="+(System.Text.RegularExpressions.Regex.IsMatch(ex.Message,"^[a-z_0-9]+$")?ex.Message:"hresult_"+ex.HResult)));}
        evidence.checks.Add(new Check("DPAPI_cross_user_device","not_run","No second Windows user/device was available; no portability claim."));
        evidence.checks.Add(new Check("password_delivery","unsupported","ExecuteScriptAsync has no proven document-atomic secret target; application autofill disabled; user types passwords."));
        evidence.checks.Add(new Check("real_school_source","not_run","No school URLs, login, sessions, credentials, or responses accessed. Source policy and manual entry remain unavailable."));
        evidence.checks.Add(new Check("Flutter_plugin_integration","not_run","Native SDK feasibility probe only; no Flutter implementation or milestone acceptance."));
        Write(output,evidence);return evidence.checks.Any(c=>c.status=="fail")?1:0;
    }
    static void SafeDelete(string root,string target) {
        string canonicalRoot=Owner.Resolve(root).TrimEnd('\\');string canonicalTarget=Owner.Resolve(target);
        if(!canonicalTarget.StartsWith(canonicalRoot+"\\",StringComparison.OrdinalIgnoreCase))throw new IOException("outside_experiment");
        // Browser-owned tree may not contain reparse points at deletion time.
        var pending=new Stack<string>();pending.Push(target);
        while(pending.Count>0) {
            string current=pending.Pop();
            foreach(string directory in Directory.GetDirectories(current)) {Owner.Resolve(directory);pending.Push(directory);}
            foreach(string file in Directory.GetFiles(current))if((File.GetAttributes(file)&FileAttributes.ReparsePoint)!=0)throw new IOException("reparse_file_rejected");
        }
        Directory.Delete(target,true);
        if(Directory.Exists(target))throw new IOException("delete_pending");
    }
    static int GuardSuite(string root,string output) {
        var evidence=new Evidence();evidence.command="powershell -NoProfile -ExecutionPolicy Bypass -File verification/windows/run.ps1 -Variant worker-guard -EvidencePath <chosen-evidence-file>";
        try {
            using(var owner=new Owner(root))using(var allowed=new LocalServer())using(var denied=new LocalServer()) {
                allowed.DeniedPort=denied.Port;denied.DeniedPort=denied.Port;
                string reference=Path.Combine(root,"partition-guard-reference"),guard=Path.Combine(root,"partition-worker-guard");Directory.CreateDirectory(reference);Directory.CreateDirectory(guard);
                MakeDnrExtension(reference,allowed.Port);MakeDnrExtension(guard,allowed.Port,true);
                foreach(string mode in new[]{"guardReference","guard","guardRestart"}) {
                    allowed.Clear();denied.Clear();
                    string p=mode=="guardReference"?reference:guard,result=Path.Combine(root,mode+".json");
                    Evidence sub;
                    using(var udp=new LocalUdpProbe()) {
                        var child=Child("browser "+Quote(p)+" "+mode+" "+allowed.Port+" "+denied.Port+" "+Quote(result)+" "+udp.Port);Wait(child,45000);
                        sub=json.Deserialize<Evidence>(File.ReadAllText(result));
                        bool ran=sub.checks.Any(item=>item.id=="WebRTC_probe_execution_"+mode&&item.status=="pass");
                        bool referenceProbe=mode=="guardReference";
                        evidence.checks.Add(new Check("WebRTC_UDP_receiver_"+mode,udp.Failure==null,"UDP receiver fault="+(udp.Failure??"none")+"; unexpected receiver exceptions fail validation."));
                        evidence.checks.Add(new Check("WebRTC_UDP_outbound_"+mode,ran&&udp.Failure==null?(referenceProbe?udp.Count>0:udp.Count==0):false,"Synthetic loopback UDP datagrams="+udp.Count+"; native RTC probe executed="+ran+". Count only, body discarded/zeroed; guarded UDP receipt is an outbound-policy gap."));
                    }
                    evidence.runtime=sub.runtime;evidence.checks.AddRange(sub.checks);evidence.deletePending|=sub.deletePending;
                    bool guarded=mode!="guardReference";
                    foreach(string kind in new[]{"worker","shared","sw"}) {
                        evidence.checks.Add(new Check("WorkerGuard_server_"+mode+"_"+kind+"_execution",guarded?allowed.Count("/guard-"+kind+"-started")==0:allowed.Count("/guard-"+kind+"-started")>0,"Synthetic worker execution sentinel receipts="+allowed.Count("/guard-"+kind+"-started")));
                        evidence.checks.Add(new Check("WorkerGuard_server_"+mode+"_"+kind+"_script",guarded?allowed.Count("/guard-"+kind+".js")==0:allowed.Count("/guard-"+kind+".js")>0,"Synthetic worker script receipts="+allowed.Count("/guard-"+kind+".js")));
                        foreach(bool deny in new[]{false,true}) {
                            int receipts=(deny?denied:allowed).Count("/guard-"+kind+"-ws-"+(deny?"denied":"ok"));
                            bool matches=guarded?receipts==0:(kind=="worker"?receipts==0:receipts>0);
                            evidence.checks.Add(new Check("WorkerGuard_server_"+mode+"_"+kind+"_ws_"+(deny?"denied":"allowed"),matches,"Synthetic handshake receipts="+receipts+"; unguarded shared/SW reference must demonstrate bypass, guarded sources must be zero."));
                        }
                    }
                    evidence.checks.Add(new Check("WorkerGuard_original_CSP_preserved_"+mode,allowed.Count("/guard-original-csp-image-denied")==0,"Original img-src none still rejects image after static worker-src CSP append."));
                }
                if(!evidence.deletePending) {SafeDelete(root,reference);SafeDelete(root,guard);evidence.checks.Add(new Check("WorkerGuard_UDF_cleanup",!Directory.Exists(reference)&&!Directory.Exists(guard),"Fresh reference and guarded partitions drained and physically removed."));}
            }
        } catch(Exception ex) {evidence.deletePending=true;evidence.checks.Add(new Check("WorkerGuard_suite_exception",false,ex.GetType().FullName));}
        evidence.checks.Add(new Check("WorkerGuard_WebTransport","not_run","WebTransport/QUIC connection enforcement remains unverified; constructor presence is only API surface evidence."));
        evidence.checks.Add(new Check("WorkerGuard_real_source_compatibility","not_run","Source may require workers; no real school access or readonly endpoint policy established. This candidate does not close V-02."));
        Write(output,evidence);return evidence.checks.Any(item=>item.status=="fail")?1:0;
    }
    static int ConnectionAllowlistSuite(string root,string output,bool onlyHttps=false) {
        var evidence=new Evidence();evidence.command="powershell -NoProfile -ExecutionPolicy Bypass -File verification/windows/run.ps1 -Variant "+(onlyHttps?"connection-allowlist-https":"connection-allowlist")+" -EvidencePath <new-evidence-file>";
        evidence.checks.Add(new Check("CAL_configuration","info","DNR GET-only plus appended worker-src none for both fresh profiles. CAL profile adds static set Connection-Allowlist: (\"http://127.0.0.1:<allowedPort>/*\"); redirects=block; webrtc=block. No feature-enabling browser arguments configured. Inherited environment argument present="+!String.IsNullOrEmpty(Environment.GetEnvironmentVariable("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"))+"."));
        try {
            using(var owner=new Owner(root))using(var allowed=new LocalServer(true))using(var denied=new LocalServer(true)) {
                allowed.DeniedPort=denied.Port;
                if(!onlyHttps) {
                var partitions=new List<string>();
                var referencePositives=new HashSet<string>();
                foreach(string context in new[]{"main","frame","srcdoc","aboutblank","blob"}) {
                    string reference=Path.Combine(root,"partition-cal-reference-"+context),guard=Path.Combine(root,"partition-cal-"+context);Directory.CreateDirectory(reference);Directory.CreateDirectory(guard);partitions.Add(reference);partitions.Add(guard);
                    MakeDnrExtension(reference,allowed.Port,true);MakeDnrExtension(guard,allowed.Port,true,true);
                foreach(string mode in new[]{"calReference","cal","calRestart"}) {
                    string p=mode=="calReference"?reference:guard,result=Path.Combine(root,mode+"-"+context+".json");
                    var stuns=new Dictionary<string,LocalUdpProbe>();var turns=new Dictionary<string,LocalTcpCountProbe>();var transports=new Dictionary<string,LocalUdpProbe>();
                    try {
                        var targets=new Dictionary<string,object>();
                            stuns[context]=new LocalUdpProbe(true);turns[context]=new LocalTcpCountProbe();transports[context]=new LocalUdpProbe(true);
                            targets[context]=new {stun=stuns[context].Port,turn=turns[context].Port,wt=transports[context].Port};
                        allowed.Clear();denied.Clear();allowed.CalScript=ConnectionScript(targets,allowed.Port);allowed.CalWideFixture=mode!="calReference";
                        var child=Child("browser "+Quote(p)+" "+mode+" "+allowed.Port+" "+denied.Port+" "+Quote(result)+" 0 "+context);Wait(child,45000);
                        var sub=json.Deserialize<Evidence>(File.ReadAllText(result));RecordRuntime(evidence,sub.runtime);evidence.deletePending|=sub.deletePending;
                        foreach(string channel in new[]{"stun","turn","wt"}) {
                            int count=channel=="stun"?stuns[context].Count:channel=="turn"?turns[context].Count:transports[context].Count;
                            string fault=channel=="stun"?stuns[context].Failure:channel=="turn"?turns[context].Failure:transports[context].Failure;
                            bool ran=sub.checks.Any(item=>item.id=="CAL_attempt_"+mode+"_"+context+"_"+channel&&item.status=="pass");
                            if(mode=="calReference"&&ran&&fault==null&&count>0)referencePositives.Add(context+"_"+channel);
                            bool positive=referencePositives.Contains(context+"_"+channel);
                            evidence.checks.Add(new Check("CAL_receipt_"+mode+"_"+context+"_"+channel,ran&&fault==null&&positive&&(mode=="calReference"?count>0:count==0),"Actual loopback "+(channel=="turn"?"TCP accepted connections":"UDP packets")+"="+count+"; native attempt validated="+ran+"; matching unguarded network positive="+positive+"; receiver fault="+(fault??"none")+". TURN receiver never reads bytes; UDP bytes zeroed/discarded. WebTransport target is unallowlisted HTTPS, not allowed-target proof."));
                        }
                        foreach(var item in sub.checks){item.id+="_case_"+context;evidence.checks.Add(item);}
                        foreach(string kind in new[]{"worker","shared","sw"})foreach(string path in new[]{"/guard-"+kind+".js","/guard-"+kind+"-started"})evidence.checks.Add(new Check("CAL_worker_receipt_"+mode+path,allowed.Count(path)==0,"Native worker script/execution receipts="+allowed.Count(path)+"."));
                        evidence.checks.Add(new Check("CAL_server_document_response_"+mode+"_"+context,allowed.CountWritten("/storage")>0&&allowed.CountWritten("/guard")>0,"Known synthetic /storage receipts="+allowed.Count("/storage")+"/responses="+allowed.CountWritten("/storage")+"; /guard receipts="+allowed.Count("/guard")+"/responses="+allowed.CountWritten("/guard")+". Dedicated receiver threads avoid ThreadPool starvation."));
                        evidence.checks.Add(new Check("CAL_original_CSP_"+mode,allowed.Count("/guard-original-csp-image-denied")==0,"Original server img-src none remains effective under append worker-src none."));
                        evidence.checks.Add(new Check("CAL_wide_header_fixture_"+mode,"info",!allowed.CalWideFixture?"Server responses contain no CAL; worker/network fixture enabled="+(allowed.CalScript!=null)+".":"Server synthetic document/frame responses originally carry wider CAL with webrtc=allow. Static DNR set replaces it; zero RTC receipts must demonstrate effective overwrite. Real stricter source policies require conservative preservation/rejection, not unconditional set."));
                    } finally {
                        foreach(var receiver in stuns.Values)receiver.Dispose();foreach(var receiver in turns.Values)receiver.Dispose();foreach(var receiver in transports.Values)receiver.Dispose();
                    }
                }
                }
                if(!evidence.deletePending) {foreach(string p in partitions)SafeDelete(root,p);evidence.checks.Add(new Check("CAL_UDF_cleanup",partitions.All(p=>!Directory.Exists(p)),"All browser processes drained before verified in-root physical deletion."));}
                }
                using(var fixture=new LocalHttpsFixture(root)) {
                    var httpsPartitions=new List<string>();
                    foreach(string context in new[]{"main","frame","srcdoc","aboutblank","blob"}) {
                        string reference=Path.Combine(root,"partition-cal-https-reference-"+context),guard=Path.Combine(root,"partition-cal-https-"+context);Directory.CreateDirectory(reference);Directory.CreateDirectory(guard);httpsPartitions.Add(reference);httpsPartitions.Add(guard);
                        File.WriteAllText(Path.Combine(reference,"https-target.json"),json.Serialize(fixture.Ready));File.WriteAllText(Path.Combine(guard,"https-target.json"),json.Serialize(fixture.Ready));
                        MakeDnrExtension(reference,allowed.Port,true,false,fixture.Ready);MakeDnrExtension(guard,allowed.Port,true,true,fixture.Ready);
                        bool httpsPositive=false;
                        foreach(string mode in new[]{"calReference","cal","calRestart"}) {
                            string p=mode=="calReference"?reference:guard,result=Path.Combine(root,"https-"+mode+"-"+context+".json");
                            fixture.Control("reset");allowed.Clear();denied.Clear();allowed.CalScript=HttpsConnectionScript(fixture.Ready,allowed.Port);allowed.CalWideFixture=mode!="calReference";
                            var child=Child("browser "+Quote(p)+" "+mode+" "+allowed.Port+" "+denied.Port+" "+Quote(result)+" 0 "+context);Wait(child,45000);
                            var sub=json.Deserialize<Evidence>(File.ReadAllText(result));RecordRuntime(evidence,sub.runtime);evidence.deletePending|=sub.deletePending;
                            bool ran=sub.checks.Any(item=>item.id=="CAL_HTTPS_WT_attempt_"+mode+"_"+context&&item.status=="pass");
                            var snapshot=fixture.Control("snapshot");var counters=(Dictionary<string,object>)snapshot["counters"];
                            int get=Convert.ToInt32(counters["https_get_query"]),udp=Convert.ToInt32(counters["quic_udp_datagrams"]),connect=Convert.ToInt32(counters["webtransport_connects"]),echo=Convert.ToInt32(counters["webtransport_echoes"]);
                            var faultNames=((System.Collections.IEnumerable)snapshot["fault_types"]).Cast<object>().Select(item=>Convert.ToString(item)).Where(item=>System.Text.RegularExpressions.Regex.IsMatch(item,"^[A-Za-z0-9_.]+$")).ToArray();
                            var faultContexts=((System.Collections.IEnumerable)snapshot["fault_contexts"]).Cast<object>().Select(item=>Convert.ToString(item)).Where(item=>System.Text.RegularExpressions.Regex.IsMatch(item,"^[A-Za-z0-9_.:;=]+$")).ToArray();
                            evidence.checks.Add(new Check("CAL_HTTPS_fixture_fault_context_"+mode+"_"+context,"info",String.Join("|",faultContexts)));
                            int faults=((System.Collections.IEnumerable)snapshot["fault_types"]).Cast<object>().Count();
                            if(mode=="calReference")httpsPositive=ran&&faults==0&&get>0&&udp>0&&connect>0&&echo>0;
                            evidence.checks.Add(new Check("CAL_HTTPS_receipts_"+mode+"_"+context,ran&&faults==0&&httpsPositive&&get>0&&(mode=="calReference"?udp>0&&connect>0&&echo>0:udp==0&&connect==0&&echo==0),"Same exact HTTPS /query endpoint counters: GET="+get+"; QUIC UDP="+udp+"; WT CONNECT="+connect+"; fixed datagram echo="+echo+"; matching reference network positive="+httpsPositive+"; fault types="+String.Join(",",faultNames)+"; type count="+faults+". Reference has native CONNECT allowance; guard uses higher-priority CONNECT block without resourceTypes."));
                            foreach(var item in sub.checks){item.id+="_https_case_"+context;evidence.checks.Add(item);}
                        }
                    }
                    if(!evidence.deletePending){foreach(string p in httpsPartitions)SafeDelete(root,p);evidence.checks.Add(new Check("CAL_HTTPS_UDF_cleanup",httpsPartitions.All(p=>!Directory.Exists(p)),"All HTTPS-only profiles drained and physically removed."));}
                    bool shutdown=fixture.Stop();evidence.checks.Add(new Check("CAL_HTTPS_fixture_shutdown",shutdown,"Hidden local fixture stop/exit0/no-stderr validated="+shutdown+"; stderr nonempty line count="+fixture.StderrLines+"; stderr pipe drained="+fixture.StderrDrained+"; stop fault count="+fixture.StopFaultCount+"; stop fault types="+fixture.StopFaultNames+". Listener/certificate cleanup confirmation required."));
                }
            }
        } catch(Exception ex) {evidence.deletePending=true;evidence.checks.Add(new Check("CAL_suite_exception",false,ex.GetType().FullName+"; code="+(System.Text.RegularExpressions.Regex.IsMatch(ex.Message,"^[a-z_]+$")?ex.Message:"unavailable")));}
        evidence.checks.Add(new Check("CAL_scope","not_run","Real-source compatibility remains untested. CAL alone does not block WebTransport to allowed HTTPS URLs; method CONNECT block is tested separately against the same HTTPS GET endpoint. Renderer crashes are failures, never zero-receipt successes."));
        Write(output,evidence);return evidence.checks.Any(item=>item.status=="fail")?1:0;
    }
    static int MinimalCalSuite(string root,string output,bool navigate=false) {
        var evidence=new Evidence();evidence.command="powershell -NoProfile -ExecutionPolicy Bypass -File verification/windows/run.ps1 -Variant "+(navigate?"connection-allowlist-minimal-navigation":"connection-allowlist-minimal")+" -EvidencePath <new-evidence-file>";
        try {using(var owner=new Owner(root))using(var allowed=new LocalServer(true))using(var denied=new LocalServer(true)) {
            allowed.DeniedPort=denied.Port;var partitions=new List<string>();bool referencePositive=false;
            foreach(string mode in navigate?new[]{"calMinimalNavigateReference","calMinimalNavigate","calMinimalNavigateRestart","calDirectNavigate","calDirectNavigateRestart"}:new[]{"calMinimalReference","calMinimal","calMinimalRestart","calDirect","calDirectRestart"}) {
                string group=mode.EndsWith("Reference")?"reference":mode.StartsWith("calDirect")?"direct":"injected",p=Path.Combine(root,"partition-minimal-"+group),result=Path.Combine(root,mode+".json");
                if(!Directory.Exists(p)){Directory.CreateDirectory(p);partitions.Add(p);MakeDnrExtension(p,allowed.Port,true,group=="injected");}
                allowed.DirectCalHeader=group=="direct"?"(\"http://127.0.0.1:"+allowed.Port+"/*\"); redirects=block; webrtc=block":null;
                using(var udp=new LocalUdpProbe(true)) {
                    var child=Child("browser "+Quote(p)+" "+mode+" "+allowed.Port+" "+denied.Port+" "+Quote(result)+" "+udp.Port);Wait(child,45000);
                    var sub=json.Deserialize<Evidence>(File.ReadAllText(result));RecordRuntime(evidence,sub.runtime);evidence.checks.AddRange(sub.checks);evidence.deletePending|=sub.deletePending;
                    bool ran=sub.checks.Any(item=>item.id=="CAL_minimal_RTC_"+mode&&item.status=="pass");
                    if(group=="reference")referencePositive=ran&&udp.Failure==null&&udp.Count>0;
                    evidence.checks.Add(new Check("CAL_minimal_receipt_"+mode,ran&&udp.Failure==null&&referencePositive&&(group=="reference"?udp.Count>0:udp.Count==0),"Actual STUN UDP packets="+udp.Count+"; native single-PC execution="+ran+"; matching reference network positive="+referencePositive+"; receiver fault="+(udp.Failure??"none")+". CAL delivery="+group+"; all UDP bytes zeroed/discarded."));
                }
            }
            if(!evidence.deletePending){foreach(string p in partitions)SafeDelete(root,p);evidence.checks.Add(new Check("CAL_minimal_cleanup",partitions.All(p=>!Directory.Exists(p)),"All profiles drained and physically removed."));}
        }}catch(Exception ex){evidence.deletePending=true;evidence.checks.Add(new Check("CAL_minimal_exception",false,ex.GetType().FullName));}
        evidence.checks.Add(new Check("CAL_minimal_limits","not_run","Minimal single-PC main document only; does not clear failures for worker/inherited-context/parallel WebTransport composition."));
        Write(output,evidence);return evidence.checks.Any(item=>item.status=="fail")?1:0;
    }
    static int CleanupUnopenedCal(string root,string output) {
        var evidence=new Evidence();evidence.command="WindowsProbe.exe cal-cleanup-unopened <owned-prior-run-root> <new-evidence-file>";
        try {
            string runtime=Path.GetFullPath(Path.Combine(Application.StartupPath,"..")),full=Path.GetFullPath(root);
            if(!full.StartsWith(runtime+"\\",StringComparison.OrdinalIgnoreCase)||!System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(full),"^run-[0-9a-f]{32}$"))throw new IOException("outside_experiment");
            using(var owner=new Owner(root)) {
                string[] targets={Path.Combine(root,"partition-cal-https-reference-main"),Path.Combine(root,"partition-cal-https-main")};
                if(targets.Any(p=>Directory.Exists(Path.Combine(p,"udf"))))throw new IOException("browser_assets_present");
                evidence.checks.Add(new Check("CAL_startup_no_browser_assets",true,"Previous reset-protocol failure occurred before first browser child; both exact HTTPS profile directories have no UDF. No browser file contents read."));
                foreach(string p in targets)if(Directory.Exists(p))SafeDelete(root,p);
                evidence.checks.Add(new Check("CAL_startup_residual_cleanup",targets.All(p=>!Directory.Exists(p)),"Canonical owned run root, fixed in-root profile paths, no reparse traversal, physical deletion verified."));
            }
        }catch(Exception ex){evidence.deletePending=true;evidence.checks.Add(new Check("CAL_startup_cleanup_failure",false,ex.GetType().FullName));}
        Write(output,evidence);return evidence.checks.Any(item=>item.status=="fail")?1:0;
    }
    static string ConnectionScript(Dictionary<string,object> targets,int port) {
        return "const calTargets="+json.Serialize(targets)+@";
function calProbe(context){
const ports=calTargets[context];
function stage(kind,value){top.chrome.webview.postMessage('syntheticCalStage:'+context+':'+kind+':'+value);}
function rtc(kind){return new Promise(resolve=>{let state={attempted:true,done:false,constructed:false,offer:false,rejected:false};let pc;
try{const config=kind==='stun'?{iceServers:[{urls:'stun:127.0.0.1:'+ports.stun}]}:{iceTransportPolicy:'relay',iceServers:[{urls:'turn:127.0.0.1:'+ports.turn+'?transport=tcp',username:'synthetic-user',credential:'synthetic-password'}]};
stage(kind,'beforeConstructor');pc=new RTCPeerConnection(config);stage(kind,'afterConstructor');state.constructed=true;pc.createDataChannel('synthetic');stage(kind,'afterChannel');stage(kind,'beforeOffer');pc.createOffer().then(d=>pc.setLocalDescription(d)).then(()=>{stage(kind,'afterOffer');state.offer=true;setTimeout(()=>{pc.close();state.done=true;stage(kind,'done');resolve(state);},2600);}).catch(()=>{pc.close();state.rejected=true;state.done=true;resolve(state);});}
catch(e){state.rejected=true;state.done=true;resolve(state);}});}
const wt=new Promise(resolve=>{let state={attempted:true,done:false,constructed:false,rejected:false};let transport;
try{stage('wt','beforeConstructor');transport=new WebTransport('https://127.0.0.1:'+ports.wt+'/synthetic-wt');stage('wt','afterConstructor');state.constructed=true;transport.ready.catch(()=>{state.rejected=true;});transport.closed.catch(()=>{});setTimeout(()=>{transport.close();state.done=true;stage('wt','done');resolve(state);},2600);}
catch(e){state.rejected=true;state.done=true;resolve(state);}});
Promise.all([rtc('stun'),rtc('turn'),wt]).then(values=>top.postMessage({calContext:context,stun:values[0],turn:values[1],wt:values[2]},'http://127.0.0.1:__PORT__'));
}
".Replace("__PORT__",port.ToString());
    }
    static string HttpsConnectionScript(HttpsFixtureReady target,int port) {
        return "const calHttps="+json.Serialize(target)+@";
function calHttpsProbe(context){
let state={calContext:context,http:false,attempted:false,constructed:false,ready:false,echo:false,rejected:false,done:false};let transport;
const http=fetch(calHttps.url).then(r=>{state.http=r.ok;},()=>{});
const wt=(async()=>{state.attempted=true;try{
const hash=Uint8Array.from(atob(calHttps.certificate_sha256_base64),c=>c.charCodeAt(0));
transport=new WebTransport(calHttps.url,{serverCertificateHashes:[{algorithm:'sha-256',value:hash}]});state.constructed=true;transport.closed.catch(()=>{});
await Promise.race([transport.ready,new Promise((resolve,reject)=>setTimeout(()=>reject(new Error('synthetic-timeout')),4000))]);state.ready=true;
const writer=transport.datagrams.writable.getWriter();await writer.write(new TextEncoder().encode('fixture-datagram-v1'));writer.releaseLock();
const reader=transport.datagrams.readable.getReader();const response=await Promise.race([reader.read(),new Promise((resolve,reject)=>setTimeout(()=>reject(new Error('synthetic-timeout')),1500))]);
state.echo=!response.done&&new TextDecoder().decode(response.value)==='fixture-datagram-v1-echo';reader.releaseLock();
}catch(e){state.rejected=true;}finally{try{if(transport)transport.close();}catch(e){}}})();
Promise.all([http,wt]).then(()=>{state.done=true;top.postMessage(state,'http://127.0.0.1:__PORT__');});
}
".Replace("__PORT__",port.ToString());
    }
    static void MakeDnrExtension(string root,int port,bool workerGuard=false,bool connectionAllowlist=false,HttpsFixtureReady httpsTarget=null) {
        string directory=Path.Combine(root,"static-policy");Directory.CreateDirectory(directory);
        var manifest=new Dictionary<string,object>{{"manifest_version",3},{"name","Synthetic static outbound policy"},{"version","1.0.0"},{"permissions",new[]{"declarativeNetRequest"}},{"declarative_net_request",new {rule_resources=new[]{new {id="static_policy",enabled=true,path="rules.json"}}}}};
        if(workerGuard)manifest["host_permissions"]=new[]{"http://127.0.0.1/*"};
        string[] resources={"main_frame","sub_frame","stylesheet","script","image","font","object","xmlhttprequest","ping","csp_report","media","websocket","other"};
        var rules=new List<object>{
            new {id=1,priority=1,action=new {type="block"},condition=new {regexFilter="^(https?|wss?)://",resourceTypes=resources}},
            new {id=2,priority=2,action=new {type="allow"},condition=new {regexFilter="^http://127\\.0\\.0\\.1:"+port+"/",requestMethods=new[]{"get"},resourceTypes=resources}}
        };
        if(workerGuard)rules.Add(new {id=3,priority=3,action=new {type="modifyHeaders",responseHeaders=new[]{new {header="Content-Security-Policy",operation="append",value="worker-src 'none'"}}},condition=new {regexFilter="^http://127\\.0\\.0\\.1:"+port+"/",resourceTypes=new[]{"main_frame","sub_frame"}}});
        if(connectionAllowlist)rules.Add(new {id=4,priority=4,action=new {type="modifyHeaders",responseHeaders=new[]{new {header="Connection-Allowlist",operation="set",value="(\"http://127.0.0.1:"+port+"/*\""+(httpsTarget==null?"":" \""+httpsTarget.url+"\"")+"); redirects=block; webrtc=block"}}},condition=new {regexFilter="^http://127\\.0\\.0\\.1:"+port+"/",resourceTypes=new[]{"main_frame","sub_frame"}}});
        if(httpsTarget!=null) {
            string regex="^https://127\\.0\\.0\\.1:"+httpsTarget.port+"/query$";
            rules.Add(new {id=6,priority=2,action=new {type="allow"},condition=new {regexFilter=regex,requestMethods=new[]{"get"},resourceTypes=resources}});
            if(connectionAllowlist)rules.Add(new {id=5,priority=5,action=new {type="block"},condition=new {requestMethods=new[]{"connect"}}});
            else rules.Add(new {id=5,priority=5,action=new {type="allow"},condition=new {regexFilter=regex,requestMethods=new[]{"connect"}}});
        }
        File.WriteAllText(Path.Combine(directory,"manifest.json"),json.Serialize(manifest),new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(directory,"rules.json"),json.Serialize(rules),new UTF8Encoding(false));
    }
    static void ReparseCheck(string root,Evidence evidence) {
        string target=Path.Combine(root,"junction-target"),alias=Path.Combine(root,"junction-alias");Directory.CreateDirectory(target);
        var info=new ProcessStartInfo("powershell.exe","-NoProfile -NonInteractive -Command "+Quote("New-Item -ItemType Junction -Path '"+alias.Replace("'","''")+"' -Target '"+target.Replace("'","''")+"' | Out-Null"));
        info.UseShellExecute=false;info.CreateNoWindow=true;info.WindowStyle=ProcessWindowStyle.Hidden;
        using(var child=Process.Start(info)){Wait(child,6000);if(child.ExitCode!=0)throw new IOException("junction_setup_failed");}
        bool rejected=false;try{using(var lease=new Owner(alias)){} }catch(IOException){rejected=true;}
        evidence.checks.Add(new Check("reparse_root_reject",rejected,"New local junction refused before acquiring assets."));
        // Remove only the verified alias link, never traverse or delete its target.
        if((File.GetAttributes(alias)&FileAttributes.ReparsePoint)==0)throw new IOException("junction_changed");Directory.Delete(alias,false);
    }
    static void Dpapi(Evidence evidence) {
        byte[] plain=new byte[32],entropy=new byte[24],wrong=new byte[24],cipher=null,restored=null;
        using(var random=new RNGCryptoServiceProvider()){random.GetBytes(plain);random.GetBytes(entropy);random.GetBytes(wrong);}
        try {
            cipher=ProtectedData.Protect(plain,entropy,DataProtectionScope.CurrentUser);
            restored=ProtectedData.Unprotect(cipher,entropy,DataProtectionScope.CurrentUser);
            evidence.checks.Add(new Check("DPAPI_CurrentUser_roundtrip",plain.SequenceEqual(restored),"Random fake secret roundtrip; no plaintext/ciphertext printed or persisted."));
            bool wrongRejected=false;try{byte[] invalid=ProtectedData.Unprotect(cipher,wrong,DataProtectionScope.CurrentUser);Array.Clear(invalid,0,invalid.Length);}catch(CryptographicException){wrongRejected=true;}
            evidence.checks.Add(new Check("DPAPI_wrong_entropy",wrongRejected,"Wrong entropy rejected."));
            cipher[cipher.Length/2]^=1;
            bool tamperedRejected=false;try{byte[] invalid=ProtectedData.Unprotect(cipher,entropy,DataProtectionScope.CurrentUser);Array.Clear(invalid,0,invalid.Length);}catch(CryptographicException){tamperedRejected=true;}
            evidence.checks.Add(new Check("DPAPI_tamper_reject",tamperedRejected,"Modified ciphertext rejected."));
        } finally {Array.Clear(plain,0,plain.Length);Array.Clear(entropy,0,entropy.Length);Array.Clear(wrong,0,wrong.Length);if(cipher!=null)Array.Clear(cipher,0,cipher.Length);if(restored!=null)Array.Clear(restored,0,restored.Length);}
    }
}
