import os
import json
import uuid
import logging
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from google.cloud import pubsub_v1
from google.cloud import workflows_v1
from google.cloud.workflows import executions_v1
from google.cloud.workflows.executions_v1.types import Execution

logging.basicConfig(level=logging.INFO)
app = FastAPI(title="ERP Core API - Infusiones")

PROJECT_ID = os.getenv("PROJECT_ID", "project-0eacb265-30c4-4a5a-9e8")
REGION = os.getenv("REGION", "europe-west1")
TOPIC_ID = os.getenv("PUBSUB_TOPIC", "erp-events")
WORKFLOW_NAME = os.getenv("WORKFLOW_NAME", "erp-order-orchestrator")

# Clientes de GCP
publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID.split("/")[-1]) if PROJECT_ID and TOPIC_ID else None
workflows_client = executions_v1.ExecutionsClient()

class OrderRequest(BaseModel):
    sku: str
    producto: str
    total: float
    origen: str

@app.get("/health")
def health():
    return {"status": "healthy", "service": "erp-core", "region": REGION}

@app.post("/orders")
async def create_order(order: OrderRequest):
    order_id = f"ORD-ES-{uuid.uuid4().hex[:6].upper()}"
    logging.info(f"Procesando nuevo pedido {order_id} para producto: {order.producto}")

    # 1. Publicar evento en Pub/Sub (Asíncrono)
    if topic_path:
        try:
            event_data = {
                "order_id": order_id,
                "sku": order.sku,
                "producto": order.producto,
                "total": order.total,
                "origen": order.origen,
                "event": "ORDER_CREATED"
            }
            publisher.publish(topic_path, json.dumps(event_data).encode("utf-8"))
            logging.info(f"Evento publicado en Pub/Sub {TOPIC_ID}")
        except Exception as e:
            logging.warning(f"No se pudo publicar en Pub/Sub: {e}")

    # 2. Ejecutar Cloud Workflows (Orquestación de departamentos)
    workflow_execution_id = None
    try:
        workflow_parent = f"projects/{PROJECT_ID}/locations/{REGION}/workflows/{WORKFLOW_NAME.split('/')[-1]}"
        execution = Execution(argument=json.dumps({"orderId": order_id, "producto": order.producto, "total": order.total}))
        response = workflows_client.create_execution(parent=workflow_parent, execution=execution)
        workflow_execution_id = response.name.split("/")[-1]
        logging.info(f"Flujo de trabajo iniciado: {workflow_execution_id}")
    except Exception as e:
        logging.warning(f"Error al iniciar Cloud Workflows: {e}")

    return {
        "orderId": order_id,
        "status": "CONFIRMED",
        "producto": order.producto,
        "total": order.total,
        "workflowExecution": workflow_execution_id or "local-simulated",
        "message": f"Pedido {order_id} registrado con éxito en el ERP."
    }
