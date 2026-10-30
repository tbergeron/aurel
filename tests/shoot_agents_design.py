"""Design screenshots of the real agent shelf and Agent view, VM only (opt-in, not discovered: run this module by name).

run.sh ~/Projects/aurel tests.shoot_agents_design  → PNGs in the VM's ~/aurel/test-artifacts/design.
"""
import json
import time
import unittest
from pathlib import Path
from tests.test_agents_native import ROOT, run_fixture

NOW = time.time()
DOC = 'https://docs.google.com/document/d/1FixtureDocIdForDesignShots0000000/edit'
SRC = {k: {'url': u, 'title': t, 'domain': u.split('/')[2]} for k, u, t in [
    ('rtings', 'https://www.rtings.com/headphones/reviews/best/by-feature/noise-cancelling', 'The 6 Best Noise Cancelling Headphones'),
    ('verge', 'https://www.theverge.com/headphones/best-noise-canceling', 'The best noise-canceling headphones'),
    ('sound', 'https://www.soundguys.com/best-noise-cancelling-headphones/', 'Best noise cancelling headphones'),
    ('bestbuy', 'https://www.bestbuy.com/site/searchpage.jsp?st=wh-1000xm6', 'www.bestbuy.com'),
    ('oracle', 'https://ebikeoracle.com/best/best-lightweight-electric-bikes', 'Best lightweight electric bikes')]}
RESULT = '''I checked current Amazon listings against a review roundup. These are the five cheapest in-stock e-bikes that publish a weight.

| Bike | Price | Weight | Battery |
|---|---|---|---|
| Jasion EB5 26" | $199 | 50 lb | 360 Wh |
| RPINT Mini 14 (folding) | $199 | 55 lb | 480 Wh |
| Vivi MT26 | $289 | 49 lb | 288 Wh |
| Hiboy C1 | $329 | 41 lb | 216 Wh |
| Gotrax Vibe | $349 | 46 lb | 270 Wh |

**Best value:** the RPINT Mini has the biggest battery for the price. Prices change daily, so check each listing before you buy.
[agent-result {"summary":"Found the 5 cheapest e-bikes and put the comparison in a new Google Doc."}]'''
ROWS = [
    {'id': 'a' * 32, 'title': 'Compare noise-cancelling headphones', 'brief': 'Find the best noise-cancelling headphones under $400 with measured isolation, and compare current prices.',
     'status': 'running', 'step': 'Reading bestbuy.com', 'created': NOW - 95, 'started': NOW - 94, 'directory': '/tmp/fixture',
     'steps': ['Searching the web: best noise cancelling headphones measurements', 'Reading rtings.com', 'Reading bestbuy.com'],
     'plan': ['Find measured reviews', 'Shortlist five models', 'Check current prices', 'Write the comparison'], 'completed': 2,
     'sources': [SRC['bestbuy'], SRC['rtings'], SRC['verge']],
     'timeline': [{'text': 'Looking for reviews that actually measure noise cancelling.'},
                  {'tool': 'WebSearch', 'text': 'Searching the web: best noise cancelling headphones measurements'},
                  {'sources': [SRC['rtings'], SRC['sound'], SRC['verge']]},
                  {'tool': 'WebFetch', 'text': 'Reading rtings.com', 'sources': [SRC['rtings']]},
                  {'tool': 'WebFetch', 'text': 'Reading theverge.com', 'sources': [SRC['verge']]},
                  {'text': 'Sony and Bose lead on measured isolation. Checking current prices.'},
                  {'tool': 'Bash', 'text': 'Reading bestbuy.com', 'sources': [SRC['bestbuy']]}]},
    {'id': 'b' * 32, 'title': 'Send Thursday schedule', 'brief': 'Email the crew Thursday’s shoot schedule from the shared doc.', 'status': 'needs-you', 'step': 'Waiting for you',
     'created': NOW - 40, 'started': NOW - 40, 'directory': '/tmp/fixture', 'steps': ['Using Google Drive'],
     'question': {'q': 'Send this email with Gmail?', 'cmd': 'To: crew@studio.example\nSubject: Thursday shoot schedule\n\nHi all, call time is 7:30 at Pier 70. Full schedule attached.', 'task': True, '_a': 'answers/fixture'},
     'timeline': [{'tool': 'mcp__claude_ai_Google_Drive__read_file_content', 'text': 'Using Google Drive'}, {'text': 'Drafted the email from the schedule doc.'}]},
    {'id': 'c' * 32, 'title': 'Cheapest e-bikes on Amazon', 'brief': 'Find the 5 cheapest e-bikes on Amazon, list price, weight and battery, then put the comparison in a new Google Doc.',
     'status': 'done', 'step': 'Done', 'created': NOW - 400, 'started': NOW - 399, 'ended': NOW - 368, 'seen': False, 'directory': '/tmp/fixture', 'cost': .1861,
     'summary': 'Found the 5 cheapest e-bikes and put the comparison in a new Google Doc.', 'result': RESULT, 'changes': '',
     'made': [{'title': 'Cheapest E-Bikes on Amazon – Comparison', 'url': DOC, 'type': 'application/vnd.google-apps.document'}, {'title': 'ebikes.csv', 'url': '/tmp/fixture/ebikes.csv', 'type': ''}],
     'links': [DOC], 'sources': [SRC['oracle']],
     'timeline': [{'text': 'Searching Amazon for cheap e-bikes.'}, {'tool': 'WebSearch', 'text': 'Searching the web: cheapest electric bike amazon price weight battery'},
                  {'tool': 'WebFetch', 'text': 'Reading ebikeoracle.com', 'sources': [SRC['oracle']]}, {'text': 'Five bikes publish a weight; writing the Doc.'},
                  {'tool': 'mcp__claude_ai_Google_Drive__create_file', 'text': 'Using Google Drive'}, {'made': [{'title': 'Cheapest E-Bikes on Amazon – Comparison', 'url': DOC, 'type': 'application/vnd.google-apps.document'}]}]},
    {'id': 'd' * 32, 'title': 'Book a table at Nopa', 'brief': 'Book a table for two at Nopa on Friday around 8pm.', 'status': 'failed',
     'step': 'OpenTable didn’t load, so nothing was booked. Try again in a minute.', 'result': 'OpenTable didn’t load, so nothing was booked.', 'created': NOW - 300, 'started': NOW - 299, 'ended': NOW - 280,
     'directory': '/tmp/fixture', 'timeline': [{'tool': 'WebSearch', 'text': 'Searching the web: Nopa reservations Friday'}, {'tool': 'WebFetch', 'text': 'Reading opentable.com'}]},
]

BODY = r'''let nsapp=NSApplication.shared;nsapp.setActivationPolicy(.accessory)
let out="OUTDIR"
let rows=try! JSONSerialization.jsonObject(with:Data(#"ROWS"#.utf8)) as! [[String:Any]]
let screen=NSScreen.screens[0]
// A dark, wallpaper-like backdrop so the glass reads as it does on a real desktop.
let back=NSWindow(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false);let paint=CAGradientLayer();paint.frame=screen.frame
paint.colors=[NSColor(srgbRed:0.16,green:0.20,blue:0.36,alpha:1).cgColor,NSColor(srgbRed:0.30,green:0.16,blue:0.30,alpha:1).cgColor,NSColor(srgbRed:0.06,green:0.07,blue:0.10,alpha:1).cgColor];paint.startPoint=CGPoint(x:0,y:1);paint.endPoint=CGPoint(x:1,y:0)
let backView=NSView(frame:screen.frame);backView.wantsLayer=true;backView.layer=paint;back.contentView=backView;back.orderFrontRegardless()
CGWarpMouseCursorPosition(CGPoint(x:120,y:screen.frame.height-120))   // far from the shelf, which fades near the cursor
let agentsUI=AgentPanels()
func after(_ s:Double,_ f:@escaping()->Void){DispatchQueue.main.asyncAfter(deadline:.now()+s,execute:f)}
func shot(_ name:String,_ w:NSWindow?){guard let w else{print("missing window \(name)");exit(1)};w.sharingType = .readOnly;   // real panels hide from capture; only this VM fixture lifts it
let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");let f=w.frame.insetBy(dx:-36,dy:-36).intersection(screen.frame),r="\(Int(f.minX)),\(Int(screen.frame.maxY-f.maxY)),\(Int(f.width)),\(Int(f.height))";p.arguments=["-x","-R"+r,out+"/"+name+".png"];try! p.run();p.waitUntilExit();print("shot \(name)")}
func hover(_ id:String){_=agentsUI.shelfModel.pointer(agentsUI.shelfModel.frames[id].map{[$0.midX,$0.midY]} ?? [])}
func select(_ id:String){agentsUI.js("view","select",id)}
let ids=rows.map{$0["id"] as! String}
agentsUI.receive(["event":"list","agents":rows]);agentsUI.ensureShelf()
after(2.0){agentsUI.receive(["event":"state","agent":rows[1]])}
after(3.5){shot("shelf-needs-you",agentsUI.shelf);hover(ids[0])
 after(1.0){shot("shelf-running",agentsUI.shelf);agentsUI.shelfModel.setStack("open");after(0.5){hover(ids[2])}   // the "✓ 2 done" pill opens the finished chips
  after(1.0){shot("shelf-done",agentsUI.shelf);Prefs.set("agentsHidden",true);agentsUI.openView(ids[0])
   after(3.0){shot("view-running",agentsUI.view);select(ids[1])
    after(1.2){shot("view-needs-you",agentsUI.view);select(ids[2])
     after(1.2){shot("view-done",agentsUI.view);select(ids[3])
      after(1.2){shot("view-failed",agentsUI.view);agentsUI.view?.setContentSize(NSSize(width:560,height:520));select(ids[2])
        after(1.2){shot("view-done-narrow",agentsUI.view);paint.colors=[NSColor.white.cgColor,NSColor.white.cgColor]
         agentsUI.view?.orderOut(nil);Prefs.set("agentsHidden",false);agentsUI.shelf?.orderFrontRegardless();agentsUI.shelfModel.setStack("open");after(0.5){hover(ids[1])}
         after(1.0){shot("shelf-white-backdrop",agentsUI.shelf);agentsUI.openView(ids[1])
          after(1.2){shot("view-white-backdrop",agentsUI.view);agentsUI.process?.terminate();print("design shots ok");exit(0)}}}}}}}}}}
nsapp.run()'''


class DesignShots(unittest.TestCase):
    def test_shoot(self):
        out = ROOT / 'test-artifacts' / 'design'; out.mkdir(parents=True, exist_ok=True)
        run_fixture(self, BODY.replace('OUTDIR', str(out)).replace('ROWS', json.dumps(ROWS)), 'design shots ok')


CARDS = r'''let agentsUI=AgentPanels()
let nsapp=NSApplication.shared;nsapp.setActivationPolicy(.accessory)
let out="OUTDIR",screen=NSScreen.screens[0]
let back=NSWindow(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false);let paint=CAGradientLayer();paint.frame=screen.frame
paint.colors=[NSColor(srgbRed:0.16,green:0.20,blue:0.36,alpha:1).cgColor,NSColor(srgbRed:0.30,green:0.16,blue:0.30,alpha:1).cgColor,NSColor(srgbRed:0.06,green:0.07,blue:0.10,alpha:1).cgColor];paint.startPoint=CGPoint(x:0,y:1);paint.endPoint=CGPoint(x:1,y:0)
let backView=NSView(frame:screen.frame);backView.wantsLayer=true;backView.layer=paint;back.contentView=backView;back.orderFrontRegardless()
// The main box as the app shows it: 340 pt of dark HUD glass with the native box on top.
let box=NSPanel(contentRect:NSRect(x:340,y:300,width:340,height:300),styleMask:[.nonactivatingPanel,.borderless],backing:.buffered,defer:false);box.isOpaque=false;box.backgroundColor = .clear;box.hasShadow=true;box.level = .floating
let glass=NSVisualEffectView(frame:NSRect(x:0,y:0,width:340,height:300));glass.material = .hudWindow;glass.state = .active;glass.appearance=NSAppearance(named:.darkAqua);glass.wantsLayer=true;glass.layer?.cornerRadius=18;glass.layer?.masksToBounds=true;glass.autoresizingMask=[.width,.height]
let model=BoxModel(),view=NSHostingView(rootView:BoxView(m:model));view.sizingOptions=[];view.frame=glass.bounds;view.autoresizingMask=[.width,.height];glass.addSubview(view);box.contentView=glass;box.orderFrontRegardless()
var got:[[String:Any]]=[],boxH:CGFloat=300;model.post={got.append($0)};model.onSize={if let h=$0.last,h>0{boxH=h}}
func ui(_ call:String,_ v:Any=NSNull()){model.receive(call,v)}
func after(_ s:Double,_ f:@escaping()->Void){DispatchQueue.main.asyncAfter(deadline:.now()+s,execute:f)}
func shot(_ name:String,_ done:@escaping()->Void){
 var f=box.frame;f.origin.y=f.maxY-boxH;f.size.height=boxH;box.setFrame(f,display:true)   // the app sizes its panel to what the box reports
 after(0.5){let f=box.frame.insetBy(dx:-36,dy:-36),p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");p.arguments=["-x","-R\(Int(f.minX)),\(Int(screen.frame.maxY-f.maxY)),\(Int(f.width)),\(Int(f.height))",out+"/"+name+".png"];try! p.run();p.waitUntilExit();print("shot \(name)");done()}}
let row=try! JSONSerialization.jsonObject(with:Data(#"ROW"#.utf8)) as! [String:Any]
// Each scene: the main box as the user meets it while agents exist.
let scenes:[(String,()->Void)]=[
 ("header-full-access",{ui("reset");ui("agentCount",1);ui("mode",false);ui("think");model.setStatus("Thinking through a detailed background result",true)}),
 ("header-safe-mode",{ui("mode",true)}),
 ("steer-confirmation",{ui("reset");ui("listen",true);ui("words","Only include products under $200");ui("think");ui("agentSteered",row.merging(["steer":["text":"Only include products under $200."]]){$1})}),
 ("box-badge",{ui("reset");ui("agentCount",2);ui("listen",true);ui("words","What is on my calendar this afternoon?");ui("think");ui("msg","A design review at 3:00 and a one-on-one with Maya at 4:30.")}),
 ("box-badge-needs-you",{ui("agentCount",["count":2,"attention":true])}),
 ("done-card",{ui("reset");ui("agentCount",1);ui("agentDone",row)})]
func card()->Card?{model.liveCard{if case .agent=$0{return true};return false}}
func play(_ i:Int){
 guard i<scenes.count else{
  // The done card lists what was made; its first row opens that exact thing; Esc picks Later.
  guard let c=card(),case .agent(_,_,_,_,let made,let acts,let cost,_)=c.kind else{print("no done card");exit(1)}
  let got1=[String(made.count),acts.last?.label ?? "",acts.first{$0.esc}?.key ?? "",cost ?? "",made.first?.sub ?? ""].joined(separator:"|")
  guard got1=="2|Open|esc|≈18.6¢ at API prices|Document · docs.google.com" else{print("done card wrong: \(got1)");exit(1)}
  model.tapAction(acts.last)
  guard got.contains(where:{($0["agentOpen"] as? String)==(ROWID) && ($0["target"] as? String)?.hasPrefix("https://docs.google.com/document/d/")==true}) else{print("made row did not open its target");exit(1)}
  print("card shots ok");exit(0)}
 scenes[i].1();after(1.3){
  if i==2,!(model.turns.last?.aOrb ?? false) || model.turns.last?.aText != "Told the Cheapest e-bikes on Amazon agent: Only include products under $200."{print("scene check failed: \(scenes[i].0): \(model.turns.last?.aText ?? "")");exit(1)}
  shot(scenes[i].0){play(i+1)}}}
after(1.0){play(0)}
nsapp.run()'''


class CardShots(unittest.TestCase):
    def test_shoot(self):
        out = ROOT / 'test-artifacts' / 'design' / 'round2'; out.mkdir(parents=True, exist_ok=True)
        row = dict(ROWS[2], status='done')
        run_fixture(self, CARDS.replace('OUTDIR', str(out)).replace('ROWID', json.dumps(row['id'])).replace('ROW', json.dumps(row)), 'card shots ok', ui=True)


PAGE = '''<body style="margin:0;font:13px -apple-system;background:#fff;color:#1d1d1f"><div style="padding:14px 18px;border-bottom:1px solid #eee;font-weight:600">Standing desks under $600</div><div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px;padding:16px">''' + ''.join(
    f'<div style="border:1px solid #eee;border-radius:10px;padding:10px"><div style="height:80px;border-radius:6px;background:linear-gradient(135deg,{c},#ddd)"></div><b style="display:block;margin-top:8px">{n}</b><span style="color:#0071e3">{p}</span></div>'
    for n, p, c in [('FlexiSpot E7', '$499', '#c9b28f'), ('Uplift V2', '$579', '#8fa3c9'), ('Vari Electric', '$545', '#9fc98f'), ('Fully Jarvis', '$589', '#c98f9f'), ('Branch Duo', '$495', '#8fc9c4'), ('IKEA Trotten', '$369', '#c9c38f')]) + '</div></body>'
OFFER = {'id': 'e' * 32, 'title': 'Compare standing desks', 'brief': 'Find the best standing desks under $600 with a stable frame, and compare prices and warranties.', 'status': 'offered', 'created': NOW, 'directory': '/tmp/fixture'}

ROUND3 = r'''setvbuf(stdout,nil,_IONBF,0)   // prints survive a crash
let nsapp=NSApplication.shared;nsapp.setActivationPolicy(.accessory)
let out="OUTDIR",screen=NSScreen.screens[0],top=screen.frame.maxY
let back=NSWindow(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false);let paint=CAGradientLayer();paint.frame=screen.frame
paint.colors=[NSColor(srgbRed:0.16,green:0.20,blue:0.36,alpha:1).cgColor,NSColor(srgbRed:0.30,green:0.16,blue:0.30,alpha:1).cgColor,NSColor(srgbRed:0.06,green:0.07,blue:0.10,alpha:1).cgColor];paint.startPoint=CGPoint(x:0,y:1);paint.endPoint=CGPoint(x:1,y:0)
let backView=NSView(frame:screen.frame);backView.wantsLayer=true;backView.layer=paint;back.contentView=backView;back.orderFrontRegardless()
func move(_ p:CGPoint){CGEvent(mouseEventSource:CGEventSource(stateID:.hidSystemState),mouseType:.mouseMoved,mouseCursorPosition:p,mouseButton:.left)?.post(tap:.cghidEventTap)}
let away=CGPoint(x:300,y:top-60);CGWarpMouseCursorPosition(away)
// A stand-in browser window the window agent drives: real pixels for its live thumbnail.
let deskPage=NSHomeDirectory()+"/desks.html";try! ##"PAGE"##.write(toFile:deskPage,atomically:true,encoding:.utf8)   // Safari will not open files from /tmp
let safari=Process();safari.executableURL=URL(fileURLWithPath:"/usr/bin/open");safari.arguments=["-g","-a","Safari",deskPage];try! safari.run()
// The main box: the native box in the stub app panel, so the orb lifts off the real card.
app.panel.setFrame(NSRect(x:24,y:top-36-330,width:340,height:330),display:true);app.panel.isOpaque=false;app.panel.backgroundColor = .clear;app.panel.level = .floating;app.panel.hasShadow=true
let glass=NSVisualEffectView(frame:NSRect(x:0,y:0,width:340,height:330));glass.material = .hudWindow;glass.state = .active;glass.appearance=NSAppearance(named:.darkAqua);glass.wantsLayer=true;glass.layer?.cornerRadius=18;glass.layer?.masksToBounds=true
let model=BoxModel(),view=NSHostingView(rootView:BoxView(m:model));view.sizingOptions=[];var boxH:CGFloat=330;model.onSize={if let h=$0.last,h>0{boxH=h}}
app.boxView.frame=glass.bounds;app.boxView.autoresizingMask=[.width,.height];view.frame=app.boxView.bounds;view.autoresizingMask=[.width,.height];app.boxView.addSubview(view)
glass.addSubview(app.boxView);app.panel.contentView=glass;app.panel.orderFrontRegardless()
let agentsUI=AgentPanels()
var rows=try! JSONSerialization.jsonObject(with:Data(#"ROWS"#.utf8)) as! [[String:Any]]
let offer=try! JSONSerialization.jsonObject(with:Data(#"OFFER"#.utf8)) as! [String:Any],offerID=offer["id"] as! String
agentsUI.receive(["event":"list","agents":rows+[offer]]);agentsUI.ensureShelf()
func after(_ s:Double,_ f:@escaping()->Void){DispatchQueue.main.asyncAfter(deadline:.now()+s,execute:f)}
func ui(_ call:String,_ v:Any=NSNull()){model.receive(call,v)}
func shoot(_ name:String,_ cocoa:NSRect){for w in [agentsUI.shelf,agentsUI.view,agentsUI.flight]{w?.sharingType = .readOnly}   // real panels hide from capture; only this VM fixture lifts it
 let f=cocoa.insetBy(dx:-30,dy:-30).intersection(screen.frame),p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
 p.arguments=["-x","-R\(Int(f.minX)),\(Int(top-f.maxY)),\(Int(f.width)),\(Int(f.height))",out+"/"+name+".png"];try! p.run();p.waitUntilExit();print("shot \(name)")}
func both()->NSRect{app.panel.frame.union(agentsUI.shelf!.frame)}
func chipCenter(_ id:String,_ done:@escaping(CGPoint)->Void){guard let r=agentsUI.shelfModel.frames[id],let f=agentsUI.shelf?.frame else{print("chip \(id) not found");return};done(CGPoint(x:f.minX+r.midX,y:top-(f.maxY-r.minY-22)))}
// The scene as a flat list of (wait, action) steps.
var steps:[(Double,()->Void)]=[],from:[Double]=[],point=CGPoint.zero
let winID=String(repeating:"f",count:32),offerJSON=String(data:try! JSONSerialization.data(withJSONObject:offer),encoding:.utf8)!
func run(_ i:Int){guard i<steps.count else{return};after(steps[i].0){steps[i].1();run(i+1)}}
steps.append((1.2,{ui("reset");ui("agentCount",2);ui("listen",true);ui("words","Compare standing desks under $600 for me");ui("think");ui("movePending")}))
steps.append((1.4,{shoot("1-handoff",both());from=model.rects["orb"].map{[$0.minX,$0.minY,$0.width,$0.height]} ?? []}))   // as App does on ⤴
steps.append((0.3,{agentsUI.flightPace=8;agentsUI.accept(offerID,from:from);ui("agentStarted")
 after(0.5){var f=app.panel.frame;f.origin.y=f.maxY-boxH;f.size.height=boxH;app.panel.setFrame(f,display:true)}}))   // the app sizes its box to the page; this stub does it once   // the swim at 1/8 speed, captured as frames
for i in 0..<7{steps.append((i==0 ? 0.25 : 0.62,{shoot("2-swim-\(i)",both().union(agentsUI.flight?.frame ?? .zero))}))}
steps.append((1.6,{agentsUI.flightPace=1;shoot("3-after-start",both());agentsUI.shelfModel.setStack("open")}))
steps.append((1.0,{shoot("4-shelf-open",agentsUI.shelf!.frame);chipCenter(offerID){point=$0}}))
steps.append((0.3,{move(point)}))
steps.append((1.0,{shoot("5-hover-controls",agentsUI.shelf!.frame);move(away)}))
steps.append((0.8,{
 let list=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
 let w=list.filter{($0[kCGWindowOwnerName as String] as? String)=="Safari" && ($0[kCGWindowLayer as String] as? Int)==0}.max{(($0[kCGWindowBounds as String] as? [String:Double])?["Width"] ?? 0)<(($1[kCGWindowBounds as String] as? [String:Double])?["Width"] ?? 0)}
 let b=w?[kCGWindowBounds as String] as? [String:Double] ?? [:]
 let target:[String:Any]=["pid":w?[kCGWindowOwnerPID as String] as? NSNumber ?? 0,"windowID":(w?[kCGWindowNumber as String] as? NSNumber)?.stringValue ?? "0","windowFrame":[b["X"] ?? 0,b["Y"] ?? 0,b["Width"] ?? 1,b["Height"] ?? 1],"window":w?[kCGWindowName as String] as? String ?? "Safari","app":"Safari"]
 print("window target \(target["windowID"]!) \(target["windowFrame"]!)")
 var win:[String:Any]=["id":winID,"title":"Order the FlexiSpot E7","brief":"Add the FlexiSpot E7 to the cart and stop before checkout.","status":"running","step":"Choosing the desk top","directory":"/tmp/fixture"]
 win["created"]=Date().timeIntervalSince1970;win["started"]=Date().timeIntervalSince1970;win["target"]=target;win["steps"]=["Opening the product page","Choosing the desk top"]
 win["timeline"]=[["tool":"mcp__hands","text":"Opening the product page"],["tool":"mcp__hands","text":"Choosing the desk top"]]
 agentsUI.receive(["event":"state","agent":win])}))
steps.append((5.5,{print("mini live \(agentsUI.mini.live) failed \(agentsUI.mini.failed) frames \(agentsUI.mini.frames) target \(agentsUI.mini.target != nil)");shoot("6-window-thumbnail",agentsUI.shelf!.frame);chipCenter(winID){point=$0}}))
steps.append((0.3,{move(point)}))
steps.append((2.0,{shoot("7-window-expanded",agentsUI.shelf!.frame);move(away)}))
steps.append((0.8,{let s=agentsUI.shelfModel;if let first=s.split(s.list).shown.first{s.dismiss([first.id])}}))
steps.append((1.0,{shoot("8-minimized",agentsUI.shelf!.frame);Prefs.set("agentsHidden",true);agentsUI.openView(winID)}))
steps.append((3.0,{shoot("9-view-window",agentsUI.view!.frame);agentsUI.process?.terminate();print("round3 shots ok");exit(0)}))
after(1.0){run(0)}
nsapp.run()'''


class Round3Shots(unittest.TestCase):
    def test_shoot(self):
        out = ROOT / 'test-artifacts' / 'design' / 'round3'; out.mkdir(parents=True, exist_ok=True)
        rows = [dict(ROWS[0], started=NOW - 95), dict(ROWS[2], seen=False)]
        run_fixture(self, ROUND3.replace('OUTDIR', str(out)).replace('PAGE', PAGE).replace('OFFER', json.dumps(OFFER)).replace('ROWS', json.dumps(rows)), 'round3 shots ok', real_mini=True, ui=True)


# Round 4: setup asks on an agent's chip, steering, and the new setup screens.
ASKS = [dict(id='1' * 32, title='Fill the expense form', brief='Fill the expense form from the receipt photo.', status='needs-you', step='Waiting for you',
             created=NOW - 50, started=NOW - 50, directory='/tmp/fixture', steps=['Reading the form'],
             timeline=[{'tool': 'Bash', 'text': 'Reading the form'}],
             question={'need': 'screen', 'q': 'Turn on Screen Recording', 'cmd': 'To see the receipt photo on your screen.', 'app': '', '_a': 'answers/1'}),
        dict(id='2' * 32, title='Track the package', brief='Check where my package is on the carrier page.', status='needs-you', step='Waiting for you',
             created=NOW - 30, started=NOW - 30, directory='/tmp/fixture', steps=['Opening the tracking page'], timeline=[{'tool': 'Bash', 'text': 'Opening the tracking page'}],
             question={'need': 'page-js', 'q': 'I can turn on page reading in Google Chrome for you', 'cmd': 'To read the tracking page without bringing Chrome forward.', 'app': 'Google Chrome', '_a': 'answers/2'}),
        dict(id='3' * 32, title='Summarize unread email', brief='Summarize my unread email from today.', status='needs-you', step='Needs Gmail',
             created=NOW - 20, started=NOW - 80, ended=NOW - 20, directory='/tmp/fixture', steps=['Looking for a mail connector'], timeline=[{'tool': 'ToolSearch', 'text': 'Looking for a mail connector'}],
             question={'need': 'connector', 'q': 'Connect Gmail in Claude', 'cmd': 'Your inbox needs the Gmail connector. Everything else is ready.', 'app': 'Gmail', '_a': 'connector'})]
STEER = dict(ROWS[0], id='4' * 32, title='Find AC filter cart', brief='Find the cheapest, best-rated 24x24x1 AC filter 3-pack on Amazon and add it to the cart.', step='Reading the window',
             sources=[], plan=[], timeline=[{'text': 'Checking the current Amazon page.'}, {'tool': 'Bash', 'text': 'Reading the window'},
                                            {'user': 'For that AC filter agent, can you steer it? I meant 12 x 24, not 24 x 24?'}, {'text': 'Switching the search to 12x24x1.'}])

ROUND4 = r'''setvbuf(stdout,nil,_IONBF,0)
let nsapp=NSApplication.shared;nsapp.setActivationPolicy(.accessory)
let out="OUTDIR",screen=NSScreen.screens[0],top=screen.frame.maxY
let back=NSWindow(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false);let paint=CAGradientLayer();paint.frame=screen.frame
paint.colors=[NSColor(srgbRed:0.16,green:0.20,blue:0.36,alpha:1).cgColor,NSColor(srgbRed:0.30,green:0.16,blue:0.30,alpha:1).cgColor,NSColor(srgbRed:0.06,green:0.07,blue:0.10,alpha:1).cgColor];paint.startPoint=CGPoint(x:0,y:1);paint.endPoint=CGPoint(x:1,y:0)
let backView=NSView(frame:screen.frame);backView.wantsLayer=true;backView.layer=paint;back.contentView=backView;back.orderFrontRegardless()
CGWarpMouseCursorPosition(CGPoint(x:120,y:top-120))
func after(_ s:Double,_ f:@escaping()->Void){DispatchQueue.main.asyncAfter(deadline:.now()+s,execute:f)}
func shoot(_ name:String,_ cocoa:NSRect){for w in [agentsUI.shelf,agentsUI.view]{w?.sharingType = .readOnly}
 let f=cocoa.insetBy(dx:-30,dy:-30).intersection(screen.frame),p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
 p.arguments=["-x","-R\(Int(f.minX)),\(Int(top-f.maxY)),\(Int(f.width)),\(Int(f.height))",out+"/"+name+".png"];try! p.run();p.waitUntilExit();print("shot \(name)")}
func fail(_ t:String)->Never{print(t);agentsUI.process?.terminate();exit(1)}
let agentsUI=AgentPanels()
let asks=try! JSONSerialization.jsonObject(with:Data(#"ASKS"#.utf8)) as! [[String:Any]]
var steer=try! JSONSerialization.jsonObject(with:Data(#"STEER"#.utf8)) as! [String:Any]
func steered()->Bool{agentsUI.shelfModel.rows.first{$0.id==steer["id"] as! String}?.steered ?? false}
func ask(_ row:[String:Any]){agentsUI.receive(["event":"state","agent":row])}
func waiting(_ row:[String:Any])->[String:Any]{var r=row,q=row["question"] as! [String:Any];q["waiting"]=true;r["question"]=q;r["step"]="Waiting for you to turn it on";return r}
agentsUI.receive(["event":"list","agents":[steer]]);agentsUI.ensureShelf()
var steps:[(Double,()->Void)]=[]
func run(_ i:Int){guard i<steps.count else{return};after(steps[i].0){steps[i].1();run(i+1)}}
steps.append((2.5,{ask(asks[0])}))
steps.append((1.5,{shoot("1-ask-macos",agentsUI.shelf!.frame)
 // Allow on the card reaches the setup flow (the real one opens System Settings and points at the switch)
 agentsUI.shelfModel.command("answer",asks[0]["id"] as! String,["answer":"y","question":(asks[0]["question"] as! [String:Any])["_a"] as Any])}))   // the card's Allow
steps.append((0.8,{if onboarding.allowed != ["screen"]{fail("Allow did not reach setup: \(onboarding.allowed)")};print("allow reached setup");ask(waiting(asks[0]))}))
steps.append((1.2,{shoot("2-ask-waiting",agentsUI.shelf!.frame);ask(asks[1])}))
steps.append((1.5,{shoot("3-ask-do-it",agentsUI.shelf!.frame);ask(asks[2])}))
steps.append((1.5,{shoot("4-ask-connector",agentsUI.shelf!.frame);for r in asks{agentsUI.receive(["event":"state","agent":r.merging(["status":"running","question":NSNull(),"step":"Working…"]){$1}])}}))
steps.append((1.2,{steer["steer"]=["ack":"Got it: 12×24, not 24×24","at":Date().timeIntervalSince1970];agentsUI.receive(["event":"steered","agent":steer])}))
steps.append((0.9,{shoot("5-steered-chip",agentsUI.shelf!.frame)
 print("steered \(steered())")}))
steps.append((4.0,{if steered(){fail("glow did not end")};print("glow ended")
 Prefs.set("agentsHidden",true);agentsUI.openView(steer["id"] as! String)}))
steps.append((3.0,{shoot("6-view-steer",agentsUI.view!.frame);ask(asks[0]);agentsUI.js("view","select",asks[0]["id"]!)}))
steps.append((1.5,{shoot("7-view-ask",agentsUI.view!.frame);agentsUI.process?.terminate();print("round4 shots ok");exit(0)}))
after(0.1){run(0)}
nsapp.run()'''

# The setup screens themselves: the native onboarding and Settings views, with live status sent in like the app does.
SETUP = r'''setvbuf(stdout,nil,_IONBF,0)
let agentsUI=AgentPanels()   // the panels code the harness includes refers to it
let nsapp=NSApplication.shared;nsapp.setActivationPolicy(.accessory)
let out="OUTDIR",screen=NSScreen.screens[0],top=screen.frame.maxY
func after(_ s:Double,_ f:@escaping()->Void){DispatchQueue.main.asyncAfter(deadline:.now()+s,execute:f)}
var got:[[String:String]]=[]
func window(_ size:NSSize,_ v:NSView)->NSWindow{
 let w=NSWindow(contentRect:NSRect(x:60,y:top-80-size.height,width:size.width,height:size.height),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
 w.titlebarAppearsTransparent=true;w.titleVisibility = .hidden
 let bg=NSVisualEffectView(frame:w.contentRect(forFrameRect:w.frame));bg.material = .underWindowBackground;bg.blendingMode = .behindWindow;bg.state = .active
 v.frame=NSRect(x:0,y:0,width:size.width,height:size.height-28);v.autoresizingMask=[.width,.height];bg.addSubview(v);w.contentView=bg;w.orderFrontRegardless();return w}
func shoot(_ name:String,_ w:NSWindow){let f=w.frame.insetBy(dx:-24,dy:-24).intersection(screen.frame),p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
 p.arguments=["-x","-R\(Int(f.minX)),\(Int(top-f.maxY)),\(Int(f.width)),\(Int(f.height))",out+"/"+name+".png"];try! p.run();p.waitUntilExit();print("shot \(name)")}
let ob=OnboardingModel();ob.post={got.append($0)}
let ow=window(NSSize(width:640,height:640),NSHostingView(rootView:OnboardingView(m:ob)))
let some:[String:Any]=["mic":true,"speech":true,"ax":true,"screen":false,"auto":true,"chrome":false,"calendar":false,"tools":true]
var steps:[(Double,()->Void)]=[]
func run(_ i:Int){guard i<steps.count else{return};after(steps[i].0){steps[i].1();run(i+1)}}
steps.append((2.0,{ob.receive("plan",["ok":true,"client":"claude","text":"Signed in. Claude Max."]);ob.receive("set",some);ob.go("perms")}))
steps.append((1.5,{shoot("8-setup-perms",ow);ob.go("agents")}))
steps.append((0.4,{ob.receive("connectors",["connected":["Gmail","Google Drive","Google Calendar","Slack"],"signin":["Notion"]])}))
steps.append((1.4,{shoot("9-setup-agents",ow)
 if !got.contains(where:{$0["do"] == "connectors"}){print("agents step did not ask for connector status");exit(1)}
 ob.receive("walk","screen")}))   // what Enable All shows while it walks the list
steps.append((1.0,{shoot("10-setup-enable-all",ow)
 ob.receive("set",["mic":true,"speech":true,"ax":true,"screen":true,"auto":true,"chrome":true,"calendar":true,"tools":true]);ob.receive("walk","")}))
steps.append((1.2,{shoot("11-setup-agents-done",ow);ob.go("try")}))
steps.append((1.2,{shoot("12-setup-try",ow);ow.orderOut(nil)
 let st=SettingsModel(),sw=window(NSSize(width:780,height:560),NSHostingView(rootView:SettingsView(m:st)));sw.appearance=NSAppearance(named:.darkAqua)   // as SettingsWindow.open
 after(2.0){st.receive("tab","account");st.receive("perms",["mic":true,"speech":true,"ax":true,"screen":true,"auto":true,"chrome":false,"calendar":false])
  st.receive("connectors",["connected":["Gmail","Google Drive","Google Calendar","Slack","Figma"],"signin":["Notion","Canva"]]);st.receive("walk","calendar")}
 after(3.2){shoot("13-settings-agents",sw);print("setup shots ok");exit(0)}}))
after(0.1){run(0)}
nsapp.run()'''

# Show, don't tell: open a real privacy pane in the VM and point at Aurel's switch with the app's own code.
def point_fixture():
    source = (ROOT / 'Aurel.swift').read_text()
    cut = lambda start, end: source[source.index(start):source.index(end, source.index(start))]
    return ('import Cocoa\n' + cut('func axAttribute(', '// AX has no public') + 'enum Hands {\n' + cut('    static func attribute(_ e: AXUIElement', '    static func array(') + '}\n'
            + cut('var ring: NSPanel?', 'func jsonString') + 'enum Onboarding {\n static let name = "Aurel"\n' + cut('    static func pointSwitch(', '    static func bundle(') + '}\n'
            + r'''setvbuf(stdout,nil,_IONBF,0)
let nsapp=NSApplication.shared;nsapp.setActivationPolicy(.accessory)
NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
Onboarding.pointSwitch("Aurel")
var tries=0
Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){t in tries+=1
 if let r=ring{t.invalidate();print("ring at \(r.frame)");r.sharingType = .readOnly
  DispatchQueue.main.asyncAfter(deadline:.now()+0.6){let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");p.arguments=["-x","OUTDIR/14-point-switch.png"];try! p.run();p.waitUntilExit();print("point shot ok");exit(0)}}
 else if tries>60{print("no switch found to point at");let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");p.arguments=["-x","OUTDIR/14-point-missing.png"];try! p.run();p.waitUntilExit();exit(1)}}
nsapp.run()''')


class Round4Shots(unittest.TestCase):
    def out(self):
        out = ROOT / 'test-artifacts' / 'design' / 'round4'; out.mkdir(parents=True, exist_ok=True); return str(out)

    def test_asks_and_steer(self):
        run_fixture(self, ROUND4.replace('OUTDIR', self.out()).replace('ASKS', json.dumps(ASKS)).replace('STEER', json.dumps(STEER)), 'round4 shots ok')

    def test_setup_screens(self):
        run_fixture(self, SETUP.replace('OUTDIR', self.out()), 'setup shots ok', ui=True)

    def test_point_at_switch(self):
        import subprocess, tempfile
        with tempfile.TemporaryDirectory() as folder:
            src = Path(folder) / 'point.swift'; src.write_text(point_fixture().replace('OUTDIR', self.out()))
            build = subprocess.run(['swiftc', str(src), '-o', str(Path(folder) / 'point')], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(Path(folder) / 'point')], capture_output=True, text=True, timeout=60)
            subprocess.run(['osascript', '-e', 'quit app "System Settings"'], capture_output=True)
            print(result.stdout.strip(), flush=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
