// Schema for the "services" collection in stardb.
// This file assumes mongosh is invoked with DB "stardb" already selected.
db.createCollection("services", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["name", "subscribers", "revenue"],
      properties: {
        name:        { bsonType: "string",  maxLength: 50 },
        subscribers: { bsonType: "int",     minimum: 0 },
        revenue:     { bsonType: "decimal" } // Decimal128
      }
    }
  },
  validationAction: "error"
});
