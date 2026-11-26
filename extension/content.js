// SalesOS Assist — fills Facebook Marketplace listing forms from your inventory.
// User clicks to fill. Never auto-publishes.
(() => {
  if (window.__salesosAssist) return;
  window.__salesosAssist = true;

  const btn = document.createElement('button');
  btn.textContent = 'Fill from Sales OS';
  btn.style.cssText = 'position:fixed;bottom:24px;right:24px;z-index:999999;background:#3b6cf5;color:#fff;border:none;border-radius:12px;padding:12px 18px;font-weight:600;font-size:14px;cursor:pointer;box-shadow:0 4px 20px rgba(59,108,245,0.4);';
  btn.onclick = () => {
    alert('SalesOS Assist: Connect to your Sales OS account to pull inventory and fill this listing. (Full implementation in the private facebook-marketplace repo.)');
  };
  document.body.append(btn);
})();