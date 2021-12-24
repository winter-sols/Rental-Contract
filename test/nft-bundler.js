const { expect } = require('chai')
const { ethers } = require('hardhat')
const { BigNumber, utils } = require('ethers')
const { getEventArgs, random32 } = require('./utils')

const link = BigNumber.from(10).pow(18)

const chainlinkConf = {
  kovan: {
    vrfCoordinator: '0xdD3782915140c8f3b190B5D67eAc6dc5760C46E9',
    link: '0xa36085F69e2889c224210F603D836748e7dC0088',
    keyHash: '0x6c3699283bda56ad74f6b855546325b68d482e983852a7a82979cc4807b641f4'
  }
}

const poolSize = 5

describe('NFTBundler', function () {
  beforeEach(async function () {
    const NFTBundler = await ethers.getContractFactory('MockNFTBundler')
    const MockNFT = await ethers.getContractFactory('MockNFT')
    const MockLink = await ethers.getContractFactory('MockErc20')

    const mockLink = await MockLink.deploy('MockLink', 'MockLink')
    this.mockNFT = await MockNFT.deploy()

    this.nftBundler = await NFTBundler.deploy(
      this.mockNFT.address, // access nft
      poolSize, // pool size
      chainlinkConf.kovan.vrfCoordinator,
      chainlinkConf.kovan.link,
      chainlinkConf.kovan.keyHash,
      link.div(10) // 0.1 LINK
    )

    this.users = await ethers.getSigners()
    
    await Promise.all([
      this.nftBundler.initialize(mockLink.address),
      mockLink.mint(this.nftBundler.address, link),
      ...Array(poolSize + 1).fill(0).map((x, i) =>
        this.mockNFT.connect(this.users[i]).mint(this.users[i].address, i)),
      ...Array(poolSize).fill(0).map((x, i) =>
        this.mockNFT.connect(this.users[0]).mint(this.users[0].address, 100 + i))
    ])

    await Promise.all([
      ...Array(poolSize).fill(0).map((x, i) =>
        this.mockNFT.connect(this.users[i]).approve(this.nftBundler.address, i)),
      ...Array(poolSize).fill(0).map((x, i) =>
        this.mockNFT.connect(this.users[0]).approve(this.nftBundler.address, 100 + i))
    ])
  })

  it('deployment fails with invalid access nft', async function () {
    const NFTBundler = await ethers.getContractFactory('MockNFTBundler')
    const MockNonNFT = await ethers.getContractFactory('MockErc20')
    const mockNonNFT = await MockNonNFT.deploy('ERC20', 'ERC20')

    await expect(NFTBundler.deploy(
      mockNonNFT.address, // access nft
      poolSize, // pool size
      chainlinkConf.kovan.vrfCoordinator,
      chainlinkConf.kovan.link,
      chainlinkConf.kovan.keyHash,
      link.div(10) // 0.1 LINK
    )).to.revertedWith('accessNFT is not ERC721')
  })

  describe('update chainlink', async function () {
    it('fails when called from non owner', async function () {
      await expect(
        this.nftBundler.connect(this.users[1]).updateChainlink(chainlinkConf.kovan.keyHash, link.div(10))
      ).to.revertedWith('Ownable: caller is not the owner')
    })

    it('update key hash', async function () {
      const deployer = this.users[0]
      const newKeyHash = '0x6c3699283bda56ad74f6b855546325b68d482e983852a7a82979cc4807b641f1'

      await expect(
        this.nftBundler.connect(deployer).updateChainlink(newKeyHash, 0)
      ).to.emit(this.nftBundler, 'ChainlinkConfigured')
        .withArgs(newKeyHash, link.div(10))
    })

    it('update fee', async function () {
      const deployer = this.users[0]
      const newFee = link.div(6)

      await expect(
        this.nftBundler
          .connect(deployer)
          .updateChainlink(utils.formatBytes32String(0), newFee)
      ).to.emit(this.nftBundler, 'ChainlinkConfigured')
        .withArgs(chainlinkConf.kovan.keyHash, newFee)
    })
  })

  describe('initializeTraitPool and finalize', async function () {
    it('finalize fails when called from non owner', async function () {
      await expect(this.nftBundler.connect(this.users[1]).finalize())
        .to.revertedWith('Ownable: caller is not the owner')
    })

    it('finalize fails when called before initialization', async function () {
      const deployer = this.users[0]
      await expect(this.nftBundler.connect(deployer).finalize())
        .to.revertedWith('Trait pool is empty')
    })

    it('initializeTraitPool fails when from non owner', async function () {
      await expect(this.nftBundler.connect(this.users[1]).initializeTraitPool([]))
        .to.revertedWith('Ownable: caller is not the owner')
    })

    it('initializeTraitPool fails when length of trait id array mismatches with pool size', async function () {
      const deployer = this.users[0]
      await expect(this.nftBundler.connect(deployer).initializeTraitPool([1, 2, 3]))
        .to.revertedWith('Invalid array length')
    })

    it('initializeTraitPool succeeds', async function () {
      const deployer = this.users[0]

      // initializeTraitPool works
      await expect(this.nftBundler.connect(deployer).initializeTraitPool([1, 2, 3, 4, 5]))
        .to.emit(this.nftBundler, 'TraitPoolInitialized')
        .withArgs(0, [1, 2, 3, 4, 5])

      await expect(this.nftBundler.connect(deployer).initializeTraitPool([5, 4, 3, 2, 1]))
        .to.emit(this.nftBundler, 'TraitPoolInitialized')
        .withArgs(1, [5, 4, 3, 2, 1])

      // finalize works
      await expect(this.nftBundler.connect(deployer).finalize())
        .to.emit(this.nftBundler, 'Finalized')

      // initializeTraitPool reverts after finalize
      await expect(this.nftBundler.connect(deployer).initializeTraitPool([5, 4, 3, 2, 1]))
        .to.revertedWith('Finalized')

      // reverts when finalize again
      await expect(this.nftBundler.connect(deployer).finalize())
        .to.revertedWith('Already finalized')
    })
  })

  describe('claim', async function () {
    it('fails before finalize', async function () {
      await expect(this.nftBundler.connect(this.users[0]).claim(0))
        .to.revertedWith('Bundler is not finalized')
    })

    it('fails if access nft is not an owner of nft id', async function () {
      const deployer = this.users[0]

      await this.nftBundler.connect(deployer).initializeTraitPool([1, 2, 3, 4, 5])
      await this.nftBundler.connect(deployer).finalize()
      await expect(this.nftBundler.connect(this.users[1]).claim(0))
        .to.revertedWith('Incorrect nft id owner')
    })

    it('fails if not enough link balance', async function () {
      const deployer = this.users[0]

      const MockLink = await ethers.getContractFactory('MockErc20')
      const mockLink = await MockLink.deploy('MockLink', 'MockLink')

      await this.nftBundler.initialize(mockLink.address)
      await this.nftBundler.connect(deployer).initializeTraitPool([1, 2, 3, 4, 5])
      await this.nftBundler.connect(deployer).finalize()
      await expect(this.nftBundler.connect(this.users[0]).claim(0))
        .to.revertedWith('Not enough LINK')
    })

    it('succeeds', async function () {
      const poolCount = 3
      const purchasedTraits = [] // every element is an array of purchased traits in corresponding pool
      const deployer = this.users[0]
      
      Array(poolCount).fill(0).forEach(async () => {
        purchasedTraits.push([])
        await this.nftBundler.connect(deployer).initializeTraitPool([1, 2, 3, 4, 5])
      })

      await this.nftBundler.connect(deployer).finalize()

      for (let i = 0; i < poolSize; i++) {
        const [ requestId ] = await getEventArgs(
          this.nftBundler.connect(this.users[i]).claim(i),
          'RandomRequestMockGenerated'
        )

        const [ claimer, nftId, traits ] = await getEventArgs(
          this.nftBundler.mockFulfillRandomness(requestId, random32()),
          'BundleClaimed'
        )

        expect(claimer).to.equal(this.users[i].address)
        expect(nftId).to.equal(i)
        expect(traits.length).to.equal(poolCount)

        // check the nft has been burnt
        expect(await this.mockNFT.exists(i)).to.equal(false)        

        // ensure purchased traits are not duplicated
        for (let j = 0; j < purchasedTraits; j++) {
          for (let k = 0; k < traits.length; k++) {
            expect(purchasedTraits[j].includes(traits[k])).to.equal(false)
          }
        }

        purchasedTraits.forEach((pool, i) => pool.push(traits[i]))
      }

      // try to claim purchased nft
      await expect(this.nftBundler.connect(this.users[0]).claim(0))
        .to.revertedWith('ERC721: owner query for nonexistent token')

      // try to claim after all has been claimed
      await expect(this.nftBundler.connect(this.users[poolSize]).claim(poolSize))
        .to.revertedWith('All traits have been claimed')

      // bundle of
      for (let i = 0; i < poolSize; i++) {
        expect(await this.nftBundler.bundleOf(this.users[i].address))
          .to.eql(purchasedTraits.map(pool => pool[i]))
      }
    })
  })

  describe('batch claim', async function () {
    it('fails before finalize', async function () {
      await expect(this.nftBundler.connect(this.users[0]).batchClaim([]))
        .to.revertedWith('Bundler is not finalized')
    })

    it('succeeds', async function () {
      const poolCount = 3
      const purchasedTraits = []
      const deployer = this.users[0]

      Array(poolCount).fill(0).forEach(async () => {
        purchasedTraits.push([])
        await this.nftBundler.connect(deployer).initializeTraitPool([1, 2, 3, 4, 5])
      })
      await this.nftBundler.connect(deployer).finalize()

      // fails when batch length is beyond remaining trait length
      await expect(this.nftBundler.connect(this.users[0]).batchClaim([1, 2, 3, 4, 5, 6]))
        .to.revertedWith('Cannot claim that amount of traits')

      const requestIds = await getEventArgs(
        this.nftBundler.connect(this.users[0]).batchClaim([100, 101, 102]),
        'RandomRequestMockGenerated',
        false
      )

      requestIds.forEach(async id => {
        await expect(this.nftBundler.mockFulfillRandomness(id[0], random32()))
          .to.emit(this.nftBundler, 'BundleClaimed')
      })
    })
  })
})
