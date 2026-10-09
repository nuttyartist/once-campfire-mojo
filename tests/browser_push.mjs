const {chromium}=await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
import {mkdtemp,rm,writeFile} from 'node:fs/promises';
const watchdog=setTimeout(()=>{console.error('Push acceptance watchdog expired');context?.close();process.exitCode=1;},120000);
const base=process.env.CAMPFIRE_PUSH_TEST_BASE || 'http://localhost:3116';
const profile=await mkdtemp('/tmp/campfire-push-chrome-');
let context;
let page;
const evidence={base,started:new Date().toISOString(),syntheticPush:false};
try {
 context=await chromium.launchPersistentContext(profile,{channel:'chrome',headless:false,ignoreDefaultArgs:['--disable-background-networking','--disable-component-update','--disable-default-apps'],permissions:['notifications']});
 page=await context.newPage();
 page.on('pageerror',e=>console.log('pageerror',e.message));
 page.on('response',r=>{if(r.status()>=400||r.request().method()==='POST')console.log(r.status(),new URL(r.url()).pathname);});
 await page.goto(base+'/first_run');
 if(await page.locator('[name="user[name]"]').count()) {
  await page.locator('[name="user[name]"]').fill('Push Acceptance');
  await page.locator('[name="user[email_address]"]').fill('push-acceptance@example.test');
  await page.locator('[name="user[password]"]').fill('Disposable local push test');
  await Promise.all([page.waitForURL('**/rooms/*'),page.locator('form:has(input[name="user[name]"]) button[type="submit"]').click()]);
 } else {
  await page.goto(base+'/session/new');
  await page.locator('[name="email_address"]').fill('push-acceptance@example.test');
  await page.locator('[name="password"]').fill('Disposable local push test');
  await Promise.all([page.waitForResponse(r=>r.request().method()==='POST'&&new URL(r.url()).pathname==='/session'),page.getByRole('button',{name:'Sign in',exact:true}).click()]);
  await page.goto(base+'/');
 }
 evidence.permission=await page.evaluate(()=>Notification.permission);
 evidence.browser=await context.browser().version();
 console.log('notification permission',evidence.permission);
 await page.locator('button[data-notifications-target=bell]').click();
 const until=async(fn,label)=>{const until=Date.now()+60000;while(Date.now()<until){if(await fn())return;await new Promise(r=>setTimeout(r,250));}throw new Error(label+' timed out');};
 await until(()=>page.evaluate(async()=>{const r=await navigator.serviceWorker.getRegistration();return !!(r&&await r.pushManager.getSubscription());}),'browser subscription');
 evidence.subscription=await page.evaluate(async()=>{const r=await navigator.serviceWorker.ready,s=await r.pushManager.getSubscription();return {host:new URL(s.endpoint).hostname,scope:r.scope,hasKeys:!!s.getKey('p256dh')&&!!s.getKey('auth')};});
 console.log('actual subscription',evidence.subscription);
 await page.goto(base+'/users/me/push_subscriptions');
 const button=page.locator('#push_subscriptions form[action$="/test_notifications"] button[type="submit"]').last();
 await button.waitFor();
 await page.evaluate(async()=>{const r=await navigator.serviceWorker.ready;for(const n of await r.getNotifications())n.close();});
 await button.click();
 await until(()=>page.evaluate(async()=>{const r=await navigator.serviceWorker.ready;return (await r.getNotifications()).some(n=>n.title==='Campfire Test');}),'external notification');
 evidence.notifications=await page.evaluate(async()=>{const r=await navigator.serviceWorker.ready;return (await r.getNotifications()).map(n=>({title:n.title,body:n.body,data:n.data}));});
 evidence.passed=true;
 await page.screenshot({path:(process.env.CAMPFIRE_PUSH_TEST_OUTPUT || '/tmp/campfire-push-acceptance')+'.png'});
 console.log('real external push received');
} catch(e) {evidence.url=page?.url();evidence.page=await page?.locator('body').innerText().catch(()=>null);evidence.passed=false;evidence.error=e.stack;console.error(e.stack);process.exitCode=1;}
finally {
 if(context){for(const page of context.pages())await page.evaluate(async()=>{const r=await navigator.serviceWorker.getRegistration();if(r){for(const n of await r.getNotifications())n.close();const s=await r.pushManager.getSubscription();if(s)await s.unsubscribe();}}).catch(()=>{});await context.close();}
 clearTimeout(watchdog);
 await rm(profile,{recursive:true,force:true});
 await writeFile((process.env.CAMPFIRE_PUSH_TEST_OUTPUT || '/tmp/campfire-push-acceptance')+'.json',JSON.stringify(evidence,null,2));
}
