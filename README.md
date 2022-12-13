# 簡易的支援 NFT 的借貸平台
*部分借款內容有參考 compound 並進行簡化

## How to Use
---

### Set Api Key in `.env`
```
// .env
API_KEY = xxxxxx
```

### Run Script
```
npx hardhat test
```

## 操作流程
---

### 質押 ETH 提供流動性與贖回
1. list market(supportMarket by admin)
2. mint with ETH
3. redeem/redeemUnderlying to get ETH back

### 借款、還款及清算
1. list market(supportNftMarket by admin)
2. mint cERC721 with ERC721
3. enterMarkets with all NFT collaterals
4. all NFT collaterals have to setApprovalForAll to lending pool(cEth)
5. borrow ETH
6. repay by repayBorrow / repayBorrowBehalf
7. liquidate & auction
    - liquidateBorrow 指定 liquidator 想要的 NFT 抵押品作為獎勵(參與競標)
    - 所有的 NFT 抵押品皆開始競標階段(除了 liquidator 指定的 NFT 外，其他抵押品初始價格皆為 0，競標者為 cERC721 合約)
    - 開放競標時間為一天，最高者可將 NFT 領走
    - 競標參與者可透過 bidNftAuction 參與競標
    - 最終得標者可透過 claimAuction 領取 NFT 獎勵