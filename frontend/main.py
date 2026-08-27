import os
import httpx
from fastapi import FastAPI, Request
from fastapi.templating import Jinja2Templates

app = FastAPI()
templates = Jinja2Templates(directory="templates")
ERP_CORE_URL = os.getenv("ERP_CORE_URL", "http://localhost:8000")

@app.get("/")
def home(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})

@app.post("/api/orders")
async def create_order(order: dict):
    async with httpx.AsyncClient() as client:
        res = await client.post(f"{ERP_CORE_URL}/orders", json=order)
        return res.json()
