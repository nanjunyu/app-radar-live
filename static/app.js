document.addEventListener('DOMContentLoaded', () => {
  
  // --- DOM 元素获取 ---
  const radarTrigger = document.getElementById('radarTrigger');
  const radarPanel = document.getElementById('radarPanel');
  const systemTime = document.getElementById('systemTime');
  const btnScan = document.getElementById('btnScan');
  const scanStatus = document.getElementById('scanStatus');
  const radarScanContainer = document.querySelector('.radar-scan-container');
  
  const gitList = document.getElementById('gitList');
  const gitCount = document.getElementById('gitCount');
  const dockerList = document.getElementById('dockerList');
  const dockerCount = document.getElementById('dockerCount');
  const brewList = document.getElementById('brewList');
  const brewCount = document.getElementById('brewCount');
  const npmList = document.getElementById('npmList');
  const npmCount = document.getElementById('npmCount');
  
  const toast = document.getElementById('toast');

  // --- 1. 模拟 macOS 菜单栏下拉弹窗切换 ---
  radarTrigger.addEventListener('click', (e) => {
    e.stopPropagation();
    radarPanel.classList.toggle('show');
    radarTrigger.classList.toggle('active');
  });

  // 点击页面其他位置，折叠控制面板
  document.addEventListener('click', (e) => {
    if (!radarPanel.contains(e.target) && e.target !== radarTrigger && !radarTrigger.contains(e.target)) {
      radarPanel.classList.remove('show');
      radarTrigger.classList.remove('active');
    }
  });

  // --- 2. 模拟 macOS 时钟更新 ---
  function updateClock() {
    const now = new Date();
    const hours = String(now.getHours()).padStart(2, '0');
    const minutes = String(now.getMinutes()).padStart(2, '0');
    systemTime.textContent = `${hours}:${minutes}`;
  }
  setInterval(updateClock, 1000);
  updateClock();

  // --- 3. 吐司消息 (Toast) ---
  function showToast(message) {
    toast.textContent = message;
    toast.classList.add('show');
    setTimeout(() => {
      toast.classList.remove('show');
    }, 1500);
  }

  // --- 4. 一键复制到剪贴板 ---
  window.copyToClipboard = function(text) {
    navigator.clipboard.writeText(text).then(() => {
      showToast('📋 升级指令已复制到剪贴板！');
    }).catch(err => {
      console.error('Failed to copy: ', err);
      showToast('⚠️ 复制失败，请手动选择复制');
    });
  };

  // --- 5. 进程强杀 (Kill Process) ---
  window.killProcess = async function(pid, name) {
    if (!confirm(`确定要强制关闭程序 "${name}" (PID: ${pid}) 吗？\n这将会立刻释放它占用的所有网络端口。`)) {
      return;
    }
    
    try {
      const response = await fetch(`/api/kill/${pid}`, {
        method: 'POST'
      });
      const data = await response.json();
      if (response.ok) {
        showToast(`⚡️ 进程 ${pid} (${name}) 已强杀！`);
        // 自动重新扫描刷新
        performScan();
      } else {
        alert(`强杀失败: ${data.detail || '未知原因'}`);
      }
    } catch (err) {
      console.error(err);
      alert('无法连接本地雷达后端服务');
    }
  };

  // --- 6. 执行扫描渲染逻辑 ---
  async function performScan() {
    btnScan.disabled = true;
    radarScanContainer.classList.add('scanning');
    scanStatus.textContent = '🚀 雷达正在深度探测本地活动进程与更新...';
    
    try {
      const response = await fetch('/api/scan');
      if (!response.ok) throw new Error('扫描失败');
      const data = await response.json();
      
      // 6.1 渲染运行中 Git 仓库项目
      renderGitProjects(data.running_git_projects);
      
      // 6.2 渲染运行中 Docker 容器
      renderDockerContainers(data.docker_containers);
      
      // 6.3 渲染 Homebrew 待更新工具
      renderBrewUpdates(data.brew_updates);
      
      // 6.4 渲染 npm 全局包
      renderNpmUpdates(data.npm_updates);
      
      scanStatus.textContent = `✅ 侦测完成。共发现 ${data.running_git_projects.length} 个运行项目，${data.docker_containers.length} 个活跃容器。`;
    } catch (err) {
      console.error(err);
      scanStatus.textContent = '❌ 侦测失败，请确保本地 AppRadar-Live 后端在运行中';
    } finally {
      btnScan.disabled = false;
      radarScanContainer.classList.remove('scanning');
    }
  }

  // --- 渲染辅助方法 ---

  function renderGitProjects(projects) {
    gitCount.textContent = projects.length;
    if (projects.length === 0) {
      gitList.innerHTML = `<div class="empty-state">暂无活跃 Git 进程</div>`;
      return;
    }
    
    gitList.innerHTML = projects.map(proj => {
      const hasUpdate = proj.update_available;
      const portString = proj.ports.join(', ');
      
      // 生成引导更新指令
      const updateCommand = `cd ${proj.path} && git pull`;
      
      return `
        <div class="radar-card">
          <div class="card-top">
            <div class="card-info">
              <div class="card-name">📂 ${proj.name}</div>
              <div class="card-meta">
                <span>PID: ${proj.pid}</span>
                <span>端口: ${portString}</span>
                <span>环境: ${proj.command}</span>
              </div>
            </div>
            <span class="status-badge ${hasUpdate ? 'has-update' : 'up-to-date'}">
              ${hasUpdate ? '有新提交' : '已是最新'}
            </span>
          </div>
          
          ${hasUpdate ? `
            <div class="changelog-box" title="${proj.changelog.join('\n')}">
              <strong>最新 Commit 日志:</strong>
              ${proj.changelog.map(log => `<div>${log}</div>`).join('')}
            </div>
          ` : ''}
          
          <div class="card-actions">
            <button class="btn-action btn-kill" onclick="killProcess(${proj.pid}, '${proj.name}')" title="强杀进程释放端口">
              ⚡️ 强杀
            </button>
            ${hasUpdate ? `
              <button class="btn-action btn-copy" onclick="copyToClipboard('${updateCommand}')" title="复制 git pull 指令">
                📋 复制更新指令
              </button>
            ` : `
              <button class="btn-action" onclick="alert('项目路径: \\n${proj.path}')" title="查看项目详情">
                🔍 详情
              </button>
            `}
          </div>
        </div>
      `;
    }).join('');
  }

  function renderDockerContainers(containers) {
    dockerCount.textContent = containers.length;
    if (containers.length === 0) {
      dockerList.innerHTML = `<div class="empty-state">暂无活跃容器</div>`;
      return;
    }
    
    dockerList.innerHTML = containers.map(c => {
      return `
        <div class="radar-card">
          <div class="card-top">
            <div class="card-info">
              <div class="card-name">🐳 ${c.name}</div>
              <div class="card-meta">
                <span>镜像: ${c.image}</span>
                <span>状态: ${c.status}</span>
              </div>
            </div>
            <span class="status-badge up-to-date">活跃中</span>
          </div>
          <div class="card-actions">
            <button class="btn-action btn-copy" onclick="copyToClipboard('${c.guide}')" title="复制重启更新命令">
              📋 复制更新引导
            </button>
          </div>
        </div>
      `;
    }).join('');
  }

  function renderBrewUpdates(brew) {
    const total = brew.formulae.length + brew.casks.length;
    brewCount.textContent = total;
    
    if (total === 0) {
      brewList.innerHTML = `<div class="empty-state">暂无待更新工具</div>`;
      return;
    }
    
    let html = '';
    
    // 渲染 Casks (桌面应用)
    brew.casks.forEach(c => {
      html += `
        <div class="radar-card">
          <div class="card-top">
            <div class="card-info">
              <div class="card-name">💻 ${c.name} (Cask)</div>
              <div class="card-meta">
                <span>当前: ${c.current_version}</span>
                <span>最新: ${c.latest_version}</span>
              </div>
            </div>
            <span class="status-badge has-update">新版本</span>
          </div>
          <div class="card-actions">
            <button class="btn-action btn-copy" onclick="copyToClipboard('${c.guide}')">
              📋 复制升级命令
            </button>
          </div>
        </div>
      `;
    });
    
    // 渲染 Formulae (命令行工具)
    brew.formulae.forEach(f => {
      html += `
        <div class="radar-card">
          <div class="card-top">
            <div class="card-info">
              <div class="card-name">🍺 ${f.name} (Formula)</div>
              <div class="card-meta">
                <span>当前: ${f.current_version}</span>
                <span>最新: ${f.latest_version}</span>
              </div>
            </div>
            <span class="status-badge has-update">新版本</span>
          </div>
          <div class="card-actions">
            <button class="btn-action btn-copy" onclick="copyToClipboard('${f.guide}')">
              📋 复制升级命令
            </button>
          </div>
        </div>
      `;
    });
    
    brewList.innerHTML = html;
  }

  function renderNpmUpdates(npm) {
    npmCount.textContent = npm.length;
    if (npm.length === 0) {
      npmList.innerHTML = `<div class="empty-state">暂无待更新全局包</div>`;
      return;
    }
    
    npmList.innerHTML = npm.map(pkg => {
      return `
        <div class="radar-card">
          <div class="card-top">
            <div class="card-info">
              <div class="card-name">📦 ${pkg.name}</div>
              <div class="card-meta">
                <span>当前: ${pkg.current_version}</span>
                <span>最新: ${pkg.latest_version}</span>
              </div>
            </div>
            <span class="status-badge has-update">新版本</span>
          </div>
          <div class="card-actions">
            <button class="btn-action btn-copy" onclick="copyToClipboard('${pkg.guide}')">
              📋 复制更新命令
            </button>
          </div>
        </div>
      `;
    }).join('');
  }

  // --- 绑定事件与初始化 ---
  btnScan.addEventListener('click', performScan);

  // 页面打开时默认自动扫描一次，展现雷达实效
  setTimeout(() => {
    performScan();
  }, 1000);

});
