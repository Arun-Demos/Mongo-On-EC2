// MongoDB schema definition for the "services" collection
const db = connect("localhost:27017/stardb");

db.createCollection("services", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["name", "subscribers", "revenue"],
      properties: {
        name:        { bsonType: "string",  maxLength: 50 },
        subscribers: { bsonType: "int",     minimum: 0 },
        revenue:     { bsonType: "decimal" }
      }
    }
  },
  validationAction: "error"
});
