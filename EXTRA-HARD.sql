create database abc2;
use abc2;

-- TABLES
CREATE TABLE Users (
    UserID INT PRIMARY KEY AUTO_INCREMENT,
    Name VARCHAR(100),
    Email VARCHAR(100) UNIQUE,
    Role ENUM('Admin', 'Vendor', 'Customer') NOT NULL
);

CREATE TABLE Vendors (
    VendorID INT PRIMARY KEY AUTO_INCREMENT,
    UserID INT UNIQUE,
    CompanyName VARCHAR(150),
    Rating DECIMAL(2,1),
    FOREIGN KEY (UserID) REFERENCES Users(UserID)
);

CREATE TABLE Products (
    ProductID INT PRIMARY KEY AUTO_INCREMENT,
    VendorID INT,
    Name VARCHAR(100),
    Price DECIMAL(10,2),
    StockQty INT,
    Category VARCHAR(50),
    AvgRating DECIMAL(2,1),
    FOREIGN KEY (VendorID) REFERENCES Vendors(VendorID)
);

CREATE TABLE Orders (
    OrderID INT PRIMARY KEY AUTO_INCREMENT,
    CustomerID INT,
    OrderDate DATETIME DEFAULT CURRENT_TIMESTAMP,
    Status ENUM('Placed', 'Shipped', 'Delivered', 'Cancelled') DEFAULT 'Placed',
    FOREIGN KEY (CustomerID) REFERENCES Users(UserID)
);

CREATE TABLE OrderItems (
    OrderItemID INT PRIMARY KEY AUTO_INCREMENT,
    OrderID INT,
    ProductID INT,
    Quantity INT,
    ItemPrice DECIMAL(10,2),
    FOREIGN KEY (OrderID) REFERENCES Orders(OrderID),
    FOREIGN KEY (ProductID) REFERENCES Products(ProductID)
);

CREATE TABLE Payments (
    PaymentID INT PRIMARY KEY AUTO_INCREMENT,
    OrderID INT,
    Amount DECIMAL(10,2),
    Method ENUM('Card', 'UPI', 'COD', 'Wallet'),
    Status ENUM('Pending', 'Completed', 'Failed') DEFAULT 'Pending',
    FOREIGN KEY (OrderID) REFERENCES Orders(OrderID)
);

CREATE TABLE Reviews (
    ReviewID INT PRIMARY KEY AUTO_INCREMENT,
    ProductID INT,
    CustomerID INT,
    Rating INT CHECK (Rating BETWEEN 1 AND 5),
    Comment TEXT,
    ReviewDate DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (ProductID) REFERENCES Products(ProductID),
    FOREIGN KEY (CustomerID) REFERENCES Users(UserID)
);

CREATE TABLE Commissions (
    CommissionID INT PRIMARY KEY AUTO_INCREMENT,
    VendorID INT,
    Month VARCHAR(7),
    TotalSales DECIMAL(12,2),
    CommissionAmount DECIMAL(12,2),
    FOREIGN KEY (VendorID) REFERENCES Vendors(VendorID)
);

CREATE TABLE AuditLog (
    LogID INT PRIMARY KEY AUTO_INCREMENT,
    UserID INT,
    Action VARCHAR(50),
    TableAffected VARCHAR(50),
    Timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (UserID) REFERENCES Users(UserID)
);


-- Users
INSERT INTO Users (Name, Email, Role) VALUES
('John Customer', 'john@example.com', 'Customer'),  -- UserID = 1
('Alice Vendor', 'alice@example.com', 'Vendor'),    -- UserID = 2
('Admin User', 'admin@example.com', 'Admin');       -- UserID = 3

-- Vendor
INSERT INTO Vendors (UserID, CompanyName, Rating) VALUES
(2, 'Alice Tech Store', 4.5); -- VendorID = 1

-- Products
INSERT INTO Products (VendorID, Name, Price, StockQty, Category, AvgRating) VALUES
(1, 'Wireless Mouse', 250.00, 100, 'Electronics', 4.5),   -- ProductID = 1
(1, 'Bluetooth Speaker', 800.00, 50, 'Electronics', 4.3), -- ProductID = 2
(1, 'USB-C Cable', 150.00, 200, 'Accessories', 4.2);      -- ProductID = 3


-- PROCEDURES
DELIMITER //
-- Validates stock. Inserts into Orders and OrderItems. Updates stock. Logs action.
CREATE PROCEDURE PlaceOrder(IN pCustomerID INT, IN pProductID INT, IN pQuantity INT)
BEGIN
    DECLARE pStock INT;
    DECLARE pPrice DECIMAL(10,2);
    DECLARE newOrderID INT;

    START TRANSACTION;

    SELECT StockQty, Price INTO pStock, pPrice FROM Products WHERE ProductID = pProductID FOR UPDATE;

    IF pStock < pQuantity THEN
        ROLLBACK;
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient stock';
    ELSE
        INSERT INTO Orders (CustomerID) VALUES (pCustomerID);
        SET newOrderID = LAST_INSERT_ID();

        INSERT INTO OrderItems (OrderID, ProductID, Quantity, ItemPrice)
        VALUES (newOrderID, pProductID, pQuantity, pPrice);

        UPDATE Products SET StockQty = StockQty - pQuantity WHERE ProductID = pProductID;

        INSERT INTO AuditLog (UserID, Action, TableAffected)
        VALUES (pCustomerID, 'PlaceOrder', 'Orders');

        COMMIT;
    END IF;
END;
//


-- Calculates total sales and commission (e.g., 10% of sales). Inserts into Commissions
CREATE PROCEDURE CalculateCommission(IN pVendorID INT, IN pMonth VARCHAR(7))
BEGIN
    DECLARE totalSales DECIMAL(12,2);
    DECLARE commission DECIMAL(12,2);

    START TRANSACTION;

    SELECT SUM(oi.Quantity * oi.ItemPrice)
    INTO totalSales
    FROM Orders o
    JOIN OrderItems oi ON o.OrderID = oi.OrderID
    JOIN Products p ON p.ProductID = oi.ProductID
    WHERE p.VendorID = pVendorID AND DATE_FORMAT(o.OrderDate, '%Y-%m') = pMonth;

    SET commission = IFNULL(totalSales * 0.10, 0);

    INSERT INTO Commissions (VendorID, Month, TotalSales, CommissionAmount)
    VALUES (pVendorID, pMonth, IFNULL(totalSales, 0), commission);

    COMMIT;
END;
//


-- Validates if the customer purchased the product. Inserts into Reviews.
CREATE PROCEDURE AddReview(IN pCustomerID INT, IN pProductID INT, IN pRating INT, IN pComment TEXT)
BEGIN
    DECLARE purchaseCount INT;

    SELECT COUNT(*) INTO purchaseCount
    FROM Orders o
    JOIN OrderItems oi ON o.OrderID = oi.OrderID
    WHERE o.CustomerID = pCustomerID AND oi.ProductID = pProductID;

    IF purchaseCount = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer has not purchased this product';
    ELSE
        INSERT INTO Reviews (ProductID, CustomerID, Rating, Comment)
        VALUES (pProductID, pCustomerID, pRating, pComment);
    END IF;
END;
//

DELIMITER ;

-- TRIGGERS
DELIMITER //
-- On OrderItems insert: Deduct stock from Products. Prevent insert if stock is insufficient.

CREATE TRIGGER trg_deduct_stock BEFORE INSERT ON OrderItems
FOR EACH ROW
BEGIN
    DECLARE currentStock INT;
    SELECT StockQty INTO currentStock FROM Products WHERE ProductID = NEW.ProductID;

    IF currentStock < NEW.Quantity THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient stock';
    ELSE
        UPDATE Products SET StockQty = StockQty - NEW.Quantity WHERE ProductID = NEW.ProductID;
    END IF;
END;
//


-- On Products update: Log changes in AuditLog if done by a vendor or admin
CREATE TRIGGER trg_product_update AFTER UPDATE ON Products
FOR EACH ROW
BEGIN
    DECLARE userId INT;
    SELECT UserID INTO userId FROM Vendors WHERE VendorID = NEW.VendorID;

    IF userId IS NOT NULL THEN
        INSERT INTO AuditLog (UserID, Action, TableAffected)
        VALUES (userId, 'Update Product', 'Products');
    END IF;
END;
//


-- On Reviews insert: Update average rating in Products.
CREATE TRIGGER trg_update_avg_rating AFTER INSERT ON Reviews
FOR EACH ROW
BEGIN
    DECLARE avgRating DECIMAL(2,1);
    SELECT AVG(Rating) INTO avgRating FROM Reviews WHERE ProductID = NEW.ProductID;
    UPDATE Products SET AvgRating = avgRating WHERE ProductID = NEW.ProductID;
END;
//

DELIMITER ;

-- TRANSACTION : PLACE ORDER + PAYMENT

-- Place order for CustomerID = 1, ProductID = 1 (Wireless Mouse), Quantity = 2
CALL PlaceOrder(1, 1, 2);

-- Add payment for the last order
INSERT INTO Payments (OrderID, Amount, Method, Status)
VALUES (LAST_INSERT_ID(), 500.00, 'Card', 'Completed');

-- Customer 1 adds review for Product 1
CALL AddReview(1, 1, 5, 'Great product! Very responsive.');

-- Calculate commission for VendorID = 1
CALL CalculateCommission(1, DATE_FORMAT(NOW(), '%Y-%m'));




-- Joins

-- 1. Top 5 products by sales
SELECT p.ProductID, p.Name, SUM(oi.Quantity) AS TotalSold
FROM OrderItems oi
JOIN Products p ON p.ProductID = oi.ProductID
GROUP BY p.ProductID, p.Name
ORDER BY TotalSold DESC
LIMIT 5;

-- 2. Vendor-wise monthly sales and commissions
SELECT v.CompanyName, c.Month, c.TotalSales, c.CommissionAmount
FROM Commissions c
JOIN Vendors v ON v.VendorID = c.VendorID
ORDER BY c.Month DESC;


-- 3. List customers with most orders and highest spend.
SELECT u.UserID, u.Name, COUNT(o.OrderID) AS TotalOrders, SUM(p.Amount) AS TotalSpend
FROM Users u
JOIN Orders o ON u.UserID = o.CustomerID
JOIN Payments p ON o.OrderID = p.OrderID
WHERE p.Status = 'Completed'
GROUP BY u.UserID, u.Name
ORDER BY TotalSpend DESC
LIMIT 5;


-- 4. Show average rating per product and vendor.
SELECT 
    p.ProductID,
    p.Name AS ProductName,
    v.CompanyName AS VendorName,
    ROUND(AVG(r.Rating), 2) AS AverageRating
FROM Reviews r 
JOIN Products p ON r.ProductID = p.ProductID
JOIN Vendors v ON p.VendorID = v.VendorID
GROUP BY p.ProductID, p.Name, v.CompanyName
ORDER BY AverageRating DESC;


SELECT * FROM Users;
SELECT * FROM Vendors;
SELECT * FROM Products;
SELECT * FROM Orders;
SELECT * FROM OrderItems;
SELECT * FROM Payments;
SELECT * FROM Reviews;
SELECT * FROM Commissions;
SELECT * FROM AuditLog;


