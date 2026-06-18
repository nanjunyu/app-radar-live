import os
import subprocess
import json
import asyncio
import logging
import signal
from typing import List, Dict, Any
from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse

# 配置日志
logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger("AppRadar-Live")

app = FastAPI(title="AppRadar-Live API", version="1.0.0")

CONFIG_PATH = os.path.join(os.path.dirname(__file__), "config.json")

# 读取配置
def load_config() -> Dict[str, Any]:
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r") as f:
                return json.load(f)
        except Exception as e:
            logger.error(f"Error loading config.json: {e}")
    return {"workspace_dirs": ["/Users/nanjunyu/workspace"], "ignored_ports": [], "ignored_containers": []}

# 异步执行 shell 命令的辅助函数
async def run_cmd_async(cmd: List[str], cwd: str = None, timeout: float = 15.0) -> str:
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        if proc.returncode != 0 and cmd[0] not in ["npm", "brew", "docker"]:
            # 忽略某些本身就会返回非零状态码的检测命令 (如 npm outdated)
            logger.warning(f"Cmd {cmd} exited with code {proc.returncode}. Error: {stderr.decode().strip()}")
        return stdout.decode().strip()
    except asyncio.TimeoutError:
        logger.error(f"Command {cmd} timed out after {timeout}s")
        return ""
    except Exception as e:
        logger.error(f"Error running command {cmd}: {e}")
        return ""

# --- 1. 运行态网络端口与项目逆向检测 ---
async def detect_running_git_projects() -> List[Dict[str, Any]]:
    config = load_config()
    workspace_dirs = config.get("workspace_dirs", [])
    ignored_ports = config.get("ignored_ports", [])
    
    # 1.1 获取 TCP LISTEN 端口
    lsof_output = await run_cmd_async(["lsof", "-iTCP", "-sTCP:LISTEN", "-P", "-n"])
    if not lsof_output:
        return []
    
    # 解析行，例如:
    # COMMAND     PID     USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    # uvicorn   80456 nanjunyu   3u  IPv4 0x73a6ea1ce83a6eb8      0t0  TCP 127.0.0.1:8000 (LISTEN)
    lines = lsof_output.split("\n")[1:]
    active_pids = {}
    
    for line in lines:
        parts = [p for p in line.split(" ") if p]
        if len(parts) < 9:
            continue
        command = parts[0]
        pid_str = parts[1]
        name_part = parts[8] # 包含 127.0.0.1:8000
        
        try:
            pid = int(pid_str)
            port = int(name_part.split(":")[-1])
            if port in ignored_ports:
                continue
            
            # 聚合同一个 PID 的所有端口
            if pid not in active_pids:
                active_pids[pid] = {
                    "command": command,
                    "ports": set(),
                    "pid": pid
                }
            active_pids[pid]["ports"].add(port)
        except Exception:
            continue

    running_projects = []
    
    # 1.2 对每一个活跃 PID 逆向检索 CWD (工作路径)
    for pid, info in active_pids.items():
        cwd_output = await run_cmd_async(["lsof", "-a", "-d", "cwd", "-p", str(pid), "-F", "n"])
        if not cwd_output:
            continue
        
        # lsof -F n 输出示例:
        # p80456
        # fcwd
        # n/Users/nanjunyu/workspace/my-project
        cwd_path = ""
        for line in cwd_output.split("\n"):
            if line.startswith("n") and len(line) > 1:
                cwd_path = line[1:].strip()
                break
        
        if not cwd_path or cwd_path == "/":
            continue
            
        # 1.3 验证工作目录是否在 workspace_dirs 中，并且是否是 Git 仓库
        is_in_workspace = any(cwd_path.startswith(w_dir) for w_dir in workspace_dirs)
        
        # 很多通过 npm / python 运行的进程可能在子目录 (如 app/client)，我们需要向上查找几层看有没有 .git
        git_root = ""
        temp_dir = cwd_path
        for _ in range(3): # 最多向上找 3 层
            if os.path.exists(os.path.join(temp_dir, ".git")):
                git_root = temp_dir
                break
            parent = os.path.dirname(temp_dir)
            if parent == temp_dir:
                break
            temp_dir = parent

        if is_in_workspace and git_root:
            # 组装运行项目基本信息
            ports_list = sorted(list(info["ports"]))
            running_projects.append({
                "name": os.path.basename(git_root),
                "pid": pid,
                "command": info["command"],
                "ports": ports_list,
                "path": git_root,
                "cwd": cwd_path
            })
            
    return running_projects

# --- 2. 各渠道的更新检测器 ---

# 2.1 Git 更新检测
async def check_git_update(repo_path: str) -> Dict[str, Any]:
    try:
        # 1. fetch 远程状态
        await run_cmd_async(["git", "fetch"], cwd=repo_path)
        # 2. 获取本地和远程 Commit
        local = await run_cmd_async(["git", "rev-parse", "HEAD"], cwd=repo_path)
        upstream = await run_cmd_async(["git", "rev-parse", "@{u}"], cwd=repo_path)
        
        local_short = local[:7] if local else "unknown"
        upstream_short = upstream[:7] if upstream else "unknown"
        
        update_available = local != upstream and local and upstream
        changelog = []
        if update_available:
            log_output = await run_cmd_async(
                ["git", "log", "HEAD..@{u}", "--oneline", "-n", "3"], 
                cwd=repo_path
            )
            if log_output:
                changelog = log_output.split("\n")
                
        return {
            "update_available": update_available,
            "current_version": local_short,
            "latest_version": upstream_short,
            "changelog": changelog
        }
    except Exception as e:
        logger.error(f"Error checking git update for {repo_path}: {e}")
        return {"update_available": False, "current_version": "unknown", "latest_version": "unknown", "changelog": []}

# 2.2 Docker 容器检测
async def check_docker_containers() -> List[Dict[str, Any]]:
    # 检测 Docker 服务是否在运行
    docker_info = await run_cmd_async(["docker", "info"])
    if not docker_info:
        return []
        
    # 获取运行中的容器
    ps_output = await run_cmd_async(["docker", "ps", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"])
    if not ps_output:
        return []
        
    containers = []
    lines = ps_output.split("\n")
    for line in lines:
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        c_id, name, image, status = parts
        
        # 略过本地构建 (无 tag 或含有 :local 的镜像)
        if ":local" in image or "/" not in image and ":" not in image:
            continue
            
        containers.append({
            "id": c_id,
            "name": name,
            "image": image,
            "status": status,
            "update_available": False, # V1 默认先只检测运行状态，由 watchtower 或前端模拟
            "latest_version": "Check via Watchtower",
            "guide": f"docker compose pull && docker compose up -d"
        })
    return containers

# 2.3 Homebrew 检测
async def check_brew_updates() -> Dict[str, Any]:
    # 异步检测 brew 是否可用
    brew_check = await run_cmd_async(["which", "brew"])
    if not brew_check:
        return {"formulae": [], "casks": []}
        
    # 一次性获取所有更新项
    outdated_json = await run_cmd_async(["brew", "outdated", "--json"])
    if not outdated_json:
        return {"formulae": [], "casks": []}
        
    try:
        data = json.loads(outdated_json)
        formulae = []
        casks = []
        
        # 兼容 brew 不同的 json 输出结构
        formula_list = data.get("formulae", []) if isinstance(data, dict) else []
        cask_list = data.get("casks", []) if isinstance(data, dict) else []
        
        for item in formula_list:
            formulae.append({
                "name": item.get("name"),
                "current_version": item.get("current_version"),
                "latest_version": item.get("latest_version"),
                "guide": f"brew upgrade {item.get('name')}"
            })
            
        for item in cask_list:
            casks.append({
                "name": item.get("name"),
                "current_version": item.get("current_version"),
                "latest_version": item.get("latest_version"),
                "guide": f"brew upgrade --cask {item.get('name')}"
            })
            
        return {"formulae": formulae, "casks": casks}
    except Exception as e:
        logger.error(f"Error parsing brew outdated json: {e}")
        return {"formulae": [], "casks": []}

# 2.4 npm 全局包检测
async def check_npm_updates() -> List[Dict[str, Any]]:
    npm_check = await run_cmd_async(["which", "npm"])
    if not npm_check:
        return []
        
    # npm outdated -g --json 在有更新时会返回 exit code 1
    outdated_json = await run_cmd_async(["npm", "outdated", "-g", "--json"])
    if not outdated_json:
        return []
        
    try:
        data = json.loads(outdated_json)
        updates = []
        for name, info in data.items():
            updates.append({
                "name": name,
                "current_version": info.get("current"),
                "latest_version": info.get("latest"),
                "guide": f"npm update -g {name}"
            })
        return updates
    except Exception as e:
        logger.error(f"Error parsing npm outdated json: {e}")
        return []

# --- 3. FastAPI 控制器接口 ---

@app.get("/api/scan")
async def scan_all() -> Dict[str, Any]:
    """一键雷达扫描所有运行中的程序与更新状态"""
    # 3.1 扫描运行中的 Git 仓库
    running_git_projects = await detect_running_git_projects()
    
    # 对运行中的 Git 仓库并发进行 Git Update 校验
    git_tasks = [check_git_update(p["path"]) for p in running_git_projects]
    git_updates = await asyncio.gather(*git_tasks)
    
    active_git_projects = []
    for proj, update in zip(running_git_projects, git_updates):
        proj.update(update)
        active_git_projects.append(proj)
        
    # 3.2 扫描 Docker 容器
    docker_containers = await check_docker_containers()
    
    # 3.3 扫描 Homebrew 全局与运行中 Casks
    brew_data = await check_brew_updates()
    
    # 3.4 扫描 npm 全局包
    npm_updates = await check_npm_updates()
    
    return {
        "status": "success",
        "running_git_projects": active_git_projects,
        "docker_containers": docker_containers,
        "brew_updates": brew_data,
        "npm_updates": npm_updates
    }

@app.post("/api/kill/{pid}")
async def kill_process(pid: int) -> Dict[str, Any]:
    """根据 PID 强杀正在运行的服务 (解决端口占用)"""
    try:
        os.kill(pid, signal.SIGKILL)
        logger.info(f"Successfully killed process {pid}")
        return {"status": "success", "message": f"进程 {pid} 已被强制终止"}
    except ProcessLookupError:
        raise HTTPException(status_code=404, detail="未找到该进程")
    except PermissionError:
        raise HTTPException(status_code=403, detail="没有权限终止该进程")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"终止进程失败: {str(e)}")

# --- 4. 静态页面伺服 ---
# 挂载 static 文件夹
static_dir = os.path.join(os.path.dirname(__file__), "static")
if not os.path.exists(static_dir):
    os.makedirs(static_dir)

app.mount("/static", StaticFiles(directory=static_dir), name="static")

@app.get("/", response_class=HTMLResponse)
async def read_index():
    index_path = os.path.join(static_dir, "index.html")
    if os.path.exists(index_path):
        with open(index_path, "r") as f:
            return HTMLResponse(content=f.read())
    return HTMLResponse(content="<h1>AppRadar-Live 前端未生成</h1>")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8045)
