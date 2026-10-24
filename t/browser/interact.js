// Clicks through the WHM page like a user would. Usage: node interact.js page.html
const { chromium } = require('playwright');
(async () => {
  const file = process.argv[2];
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  p.on('pageerror', e => errors.push(e.message));
  await p.goto('file://' + file);
  const out = {};
  const active = () => p.$eval('.bsw-panel.bsw-active', el => el.getAttribute('data-panel'));

  await p.click('a.bsw-tab[data-tab=settings]');
  out.tab_click = await active();

  // Opening a select must not leave the tab.
  await p.click('select[name=public_lang]');
  await p.keyboard.press('Escape');
  out.after_select_click = await active();
  await p.selectOption('select[name=public_lang]', 'en');
  out.select_value = await p.$eval('select[name=public_lang]', el => el.value);
  out.after_select_change = await active();

  // Switches and radio cards must toggle.
  const sw = 'input[name=alert_sms]';
  const before = await p.$eval(sw, el => el.checked);
  await p.click('label.bsw-switch:has(' + sw + ')');
  out.switch_toggled = (await p.$eval(sw, el => el.checked)) !== before;
  await p.click('.bsw-seg label:has(input[value=category])');
  out.radio = await p.$eval('input[name=section_mode]:checked', el => el.value);
  await p.fill('input[name=server_label]', 'typed');
  out.typed = await p.$eval('input[name=server_label]', el => el.value);
  out.still_settings = await active();

  // Other tabs: a check switch and an item switch.
  await p.click('a.bsw-tab[data-tab=checks]');
  const cs = 'input[name=chk_load_enabled]';
  const c0 = await p.$eval(cs, el => el.checked);
  await p.click('label.bsw-switch:has(' + cs + ')');
  out.check_switch = (await p.$eval(cs, el => el.checked)) !== c0;
  await p.click('a.bsw-tab[data-tab=items]');
  const is = 'input[name=item_own_0]';
  const i0 = await p.$eval(is, el => el.checked);
  await p.click('label.bsw-switch:has(' + is + ')');
  out.item_switch = (await p.$eval(is, el => el.checked)) !== i0;
  out.final_tab = await active();
  out.errors = errors;
  console.log(JSON.stringify(out));
  await b.close();
})().catch(e => { console.log(JSON.stringify({ fatal: String(e) })); process.exit(0); });
