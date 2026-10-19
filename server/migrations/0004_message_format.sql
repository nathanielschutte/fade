-- Which encryption scheme a message uses, so clients know how to decrypt it.
-- Format 1 is everything so far (docs/how-napsack-works.md). A future scheme
-- gets a new number; old messages keep theirs and stay readable.
ALTER TABLE messages ADD COLUMN format INTEGER NOT NULL DEFAULT 1;
