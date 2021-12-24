const { BigNumber, utils } = require('ethers')

const oneLink = BigNumber.from(10).pow(18)

const chainlinkConf = {
  kovan: {
    vrfCoordinator: '0xdD3782915140c8f3b190B5D67eAc6dc5760C46E9',
    link: '0xa36085F69e2889c224210F603D836748e7dC0088',
    keyHash: '0x6c3699283bda56ad74f6b855546325b68d482e983852a7a82979cc4807b641f4',
    fee: oneLink.div(10) // 0.1 LINK
  }
}

module.exports = async ({getNamedAccounts, deployments}) => {
  const {deploy} = deployments;
  const {deployer} = await getNamedAccounts();

  const mockNFT = await deploy('MockNFT', {
    from: deployer,
    args: [],
    log: true,
  });

  await deploy('NFTBundler', {
    from: deployer,
    args: [
      mockNFT.address, // access nft address,
      10, // pool size
      chainlinkConf.kovan.vrfCoordinator,
      chainlinkConf.kovan.link,
      chainlinkConf.kovan.keyHash,
      chainlinkConf.kovan.fee
    ],
    log: true,
  });
};
module.exports.tags = ['NFTBundler'];
