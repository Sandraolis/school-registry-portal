import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, ScanCommand, PutCommand } from "@aws-sdk/lib-dynamodb";
import { randomUUID } from "crypto";

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE_NAME;
const RESPONSE_KEY = process.env.RESPONSE_KEY;
const LABEL = process.env.ENTITY_LABEL;
const UNIQUE_FIELDS = (process.env.UNIQUE_FIELDS || "").split(",");

const headers = {
  "Content-Type": "application/json",
  "Access-Control-Allow-Origin": "*",
};
const reply = (statusCode, body) => ({ statusCode, headers, body: JSON.stringify(body) });

export const handler = async (event) => {
  const method = event.requestContext.http.method;

  if (method === "GET") {
    const { Items } = await db.send(new ScanCommand({ TableName: TABLE }));
    return reply(200, { [RESPONSE_KEY]: Items });
  }

  if (method === "POST") {
    const body = JSON.parse(event.body || "{}");
    const { Items } = await db.send(new ScanCommand({ TableName: TABLE }));
    const exists = Items.some((item) =>
      UNIQUE_FIELDS.some(
        (f) => body[f] !== undefined && String(item[f]) === String(body[f])
      )
    );
    if (exists) return reply(400, { error: `${LABEL} already exists` });

    const record = { id: randomUUID(), ...body };
    await db.send(new PutCommand({ TableName: TABLE, Item: record }));
    return reply(200, record);
  }

  return reply(405, { error: "Method not allowed" });
};