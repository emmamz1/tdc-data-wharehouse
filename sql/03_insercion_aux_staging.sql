-- ============================================================
-- TDC Data Warehouse — Tablas auxiliares de Staging
-- Base de datos: TDC_Staging
--
-- Estas tres tablas materializan la lógica de negocio más
-- compleja del pipeline antes de cargar FACT_VENTAS.
-- Deben ejecutarse en orden estricto, luego de que las tablas
-- brutas de ventas (stg_Ventas), precios (stg_Precios) y
-- descuentos (stg_Descuentos) ya estén cargadas por SSIS.
--
-- En producción, estos INSERTs se ejecutan como Execute SQL
-- Tasks dentro del paquete SSIS, entre la carga de descuentos
-- y la carga final de FACT_VENTAS al Data Warehouse.
-- ============================================================

USE TDC_Staging;
GO

-- ------------------------------------------------------------
-- PASO 1 — STG_VENTAS_CON_PRECIO
--
-- Resuelve el precio unitario vigente para cada línea de venta.
-- Lógica: para cada venta, busca en stg_Precios el registro
-- cuya fecha de vigencia sea la más reciente sin superar la
-- fecha de la transacción (MAX(Fecha_Precio) <= Fecha_Venta).
-- Esta lógica aplica tanto a ventas históricas (SQL Server,
-- hasta 2008) como a ventas actuales (MySQL, desde 2009),
-- ya que stg_Precios contiene historial completo de precios.
--
-- El INNER JOIN descarta líneas de venta sin precio registrado
-- para su producto en la fecha correspondiente (~33K filas,
-- 2% del total — comportamiento esperado y aceptado).
-- ------------------------------------------------------------

TRUNCATE TABLE STG_VENTAS_CON_PRECIO;

INSERT INTO STG_VENTAS_CON_PRECIO
    (Billing_ID, Fecha, Customer_ID, Employee_ID, Product_ID,
     Cantidad, Region, Precio_Unitario, Monto_Linea)
SELECT
    v.Billing_ID,
    CONVERT(DATE, v.Fecha, 120)                     AS Fecha,
    v.Customer_ID,
    v.Employee_ID,
    v.Product_ID,
    CAST(v.Cantidad AS INT)                         AS Cantidad,
    v.Region,
    p.Precio_Unitario,
    CAST(v.Cantidad AS INT) * p.Precio_Unitario     AS Monto_Linea
FROM stg_Ventas v
INNER JOIN (
    SELECT
        sp.Product_ID,
        CONVERT(DATE, sp.Fecha, 120)        AS Fecha_Precio,
        CAST(sp.Precio AS DECIMAL(12,4))    AS Precio_Unitario
    FROM stg_Precios sp
) p
    ON  p.Product_ID   = v.Product_ID
    AND p.Fecha_Precio = (
        SELECT MAX(p2.Fecha_Precio)
        FROM (
            SELECT Product_ID, CONVERT(DATE, Fecha, 120) AS Fecha_Precio
            FROM stg_Precios
        ) p2
        WHERE p2.Product_ID   = v.Product_ID
          AND p2.Fecha_Precio <= CONVERT(DATE, v.Fecha, 120)
    );
GO

-- ------------------------------------------------------------
-- PASO 2 — STG_MONTO_FACTURA
--
-- Agrega el monto bruto total por factura, necesario para
-- evaluar si aplica algún descuento (que opera a nivel de
-- factura completa, no por línea de producto).
-- Produce exactamente 1 fila por Billing_ID.
-- ------------------------------------------------------------

TRUNCATE TABLE STG_MONTO_FACTURA;

INSERT INTO STG_MONTO_FACTURA (Billing_ID, Monto_Bruto_Factura)
SELECT
    Billing_ID,
    SUM(Monto_Linea) AS Monto_Bruto_Factura
FROM STG_VENTAS_CON_PRECIO
GROUP BY Billing_ID;
GO

-- ------------------------------------------------------------
-- PASO 3 — STG_MEJOR_DESCUENTO
--
-- Selecciona el mejor descuento aplicable para cada factura.
-- Condiciones de elegibilidad (acumulativas):
--   1. La fecha de la venta debe estar en el período de
--      vigencia del descuento (Fecha_Desde <= Fecha <= Fecha_Hasta)
--   2. El monto bruto de la factura debe igualar o superar
--      el umbral mínimo del descuento (>= Total_Billing)
-- Si múltiples descuentos califican simultáneamente (solapamientos
-- confirmados en la tabla fuente), se aplica el de mayor porcentaje.
-- Las facturas sin descuento elegible no aparecen en esta tabla;
-- VW_FACT_VENTAS maneja ese caso con LEFT JOIN + ISNULL(..., 0).
-- ------------------------------------------------------------

TRUNCATE TABLE STG_MEJOR_DESCUENTO;

INSERT INTO STG_MEJOR_DESCUENTO (Billing_ID, Mejor_Porcentaje)
SELECT
    mf.Billing_ID,
    MAX(CAST(d.Porcentaje AS DECIMAL(5,2))) AS Mejor_Porcentaje
FROM STG_MONTO_FACTURA mf
INNER JOIN STG_VENTAS_CON_PRECIO v
    ON v.Billing_ID = mf.Billing_ID
INNER JOIN stg_Descuentos d
    ON  mf.Monto_Bruto_Factura >= CAST(d.Total_Billing AS DECIMAL(12,4))
    AND v.Fecha >= CONVERT(DATE, d.Fecha_Desde, 120)
    AND v.Fecha <= CONVERT(DATE, d.Fecha_Hasta, 120)
GROUP BY mf.Billing_ID;
GO

-- ------------------------------------------------------------
-- Verificación final (ejecutar antes de correr FACT_VENTAS)
-- ------------------------------------------------------------

SELECT
    'STG_VENTAS_CON_PRECIO' AS Tabla, COUNT(*) AS Filas FROM STG_VENTAS_CON_PRECIO
UNION ALL SELECT 'STG_MONTO_FACTURA',   COUNT(*) FROM STG_MONTO_FACTURA
UNION ALL SELECT 'STG_MEJOR_DESCUENTO', COUNT(*) FROM STG_MEJOR_DESCUENTO;

-- Resultados esperados:
-- STG_VENTAS_CON_PRECIO  ~1.642.257
-- STG_MONTO_FACTURA        ~273.298
-- STG_MEJOR_DESCUENTO       ~41.539
