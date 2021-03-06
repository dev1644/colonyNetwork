/*
  This file is part of The Colony Network.

  The Colony Network is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  The Colony Network is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with The Colony Network. If not, see <http://www.gnu.org/licenses/>.
*/

pragma solidity >=0.4.23 <0.5.0;
pragma experimental "ABIEncoderV2";

import "./ColonyAuthority.sol";
import "./EtherRouter.sol";
import "./ColonyNetworkStorage.sol";
import "./IReputationMiningCycle.sol";
import "./IColony.sol";


contract ColonyNetwork is ColonyNetworkStorage {
  // Meta Colony allowed to manage Global skills
  // All colonies are able to manage their Local (domain associated) skills
  modifier allowedToAddSkill(bool globalSkill) {
    if (globalSkill) {
      require(msg.sender == metaColony, "colony-must-be-meta-colony");
    } else {
      require(_isColony[msg.sender] || msg.sender == address(this), "colony-caller-must-be-colony");
    }
    _;
  }

  modifier skillExists(uint skillId) {
    require(skillId > 0 && skillCount >= skillId, "colony-invalid-skill-id");
    _;
  }

  function isColony(address _colony) public view returns (bool) {
    return _isColony[_colony];
  }

  function getCurrentColonyVersion() public view returns (uint256) {
    return currentColonyVersion;
  }

  function getMetaColony() public view returns (address) {
    return metaColony;
  }

  function getColonyCount() public view returns (uint256) {
    return colonyCount;
  }

  function getSkillCount() public view returns (uint256) {
    return skillCount;
  }

  function getRootGlobalSkillId() public view returns (uint256) {
    return rootGlobalSkillId;
  }

  function getColonyVersionResolver(uint256 _version) public view returns (address) {
    return colonyVersionResolver[_version];
  }

  function getSkill(uint256 _skillId) public view returns (Skill memory skill) {
    skill = skills[_skillId];
  }

  function isGlobalSkill(uint256 _skillId) public view returns (bool globalSkill) {
    globalSkill = skills[_skillId].globalSkill;
  }

  function getSkillNParents(uint256 _skillId) public view returns (uint256 nParents) {
    nParents = skills[_skillId].nParents;
  }

  function getReputationRootHash() public view returns (bytes32) {
    return reputationRootHash;
  }

  function getReputationRootHashNNodes() public view returns (uint256) {
    return reputationRootHashNNodes;
  }

  function setTokenLocking(address _tokenLocking) public
  stoppable
  auth
  {
    // Token locking address can't be changed
    require(tokenLocking == address(0x0), "colony-invalid-token-locking-address");
    tokenLocking = _tokenLocking;

    emit TokenLockingAddressSet(_tokenLocking);
  }

  function getTokenLocking() public view returns (address) {
    return tokenLocking;
  }

  function setMiningResolver(address _miningResolver) public
  stoppable
  auth
  {
    miningCycleResolver = _miningResolver;

    emit MiningCycleResolverSet(_miningResolver);
  }

  function getMiningResolver() public view returns (address) {
    return miningCycleResolver;
  }

  function createMetaColony(address _tokenAddress) public
  stoppable
  auth
  {
    require(metaColony == address(0x0), "colony-meta-colony-exists-already");
    // Add the root global skill
    skillCount += 1;
    Skill memory rootGlobalSkill;
    rootGlobalSkill.globalSkill = true;
    skills[skillCount] = rootGlobalSkill;
    rootGlobalSkillId = skillCount;

    metaColony = createColony(_tokenAddress);

    // Add the special mining skill
    this.addSkill(skillCount, false);

    emit MetaColonyCreated(metaColony, _tokenAddress, skillCount);
  }

  function createColony(address _tokenAddress) public
  stoppable
  returns (address)
  {
    require(currentColonyVersion > 0, "colony-network-not-initialised-cannot-create-colony");
    EtherRouter etherRouter = new EtherRouter();
    IColony colony = IColony(address(etherRouter));
    address resolverForLatestColonyVersion = colonyVersionResolver[currentColonyVersion];
    etherRouter.setResolver(resolverForLatestColonyVersion);

    // Creating new instance of colony's authority
    ColonyAuthority authority = new ColonyAuthority(address(colony));

    DSAuth dsauth = DSAuth(etherRouter);
    dsauth.setAuthority(authority);

    authority.setOwner(address(etherRouter));
    colony.setFounderRole(msg.sender);

    // Colony will not have owner
    dsauth.setOwner(address(0x0));

    // Initialise the root (domain) local skill with defaults by just incrementing the skillCount
    skillCount += 1;
    colonyCount += 1;
    colonies[colonyCount] = address(colony);
    _isColony[address(colony)] = true;

    colony.initialiseColony(address(this), _tokenAddress);
    emit ColonyAdded(colonyCount, address(etherRouter), _tokenAddress);

    return address(etherRouter);
  }

  function addColonyVersion(uint _version, address _resolver) public
  always
  calledByMetaColony
  {
    require(currentColonyVersion > 0, "colony-network-not-intialised-cannot-add-colony-version");

    colonyVersionResolver[_version] = _resolver;
    if (_version > currentColonyVersion) {
      currentColonyVersion = _version;
    }

    emit ColonyVersionAdded(_version, _resolver);
  }

  function initialise(address _resolver) public
  auth
  stoppable
  {
    require(currentColonyVersion == 0, "colony-network-already-initialised");
    colonyVersionResolver[1] = _resolver;
    currentColonyVersion = 1;

    emit ColonyNetworkInitialised(_resolver);
  }

  function getColony(uint256 _id) public view returns (address) {
    return colonies[_id];
  }

  function addSkill(uint _parentSkillId, bool _globalSkill) public stoppable
  skillExists(_parentSkillId)
  allowedToAddSkill(_globalSkill)
  returns (uint256)
  {
    skillCount += 1;

    Skill storage parentSkill = skills[_parentSkillId];

    // Global and local skill trees are kept separate
    require(parentSkill.globalSkill == _globalSkill, "colony-global-and-local-skill-trees-are-separate");

    Skill memory s;
    s.nParents = parentSkill.nParents + 1;
    s.globalSkill = _globalSkill;
    skills[skillCount] = s;

    uint parentSkillId = _parentSkillId;
    bool notAtRoot = true;
    uint powerOfTwo = 1;
    uint treeWalkingCounter = 1;

    // Walk through the tree parent skills up to the root
    while (notAtRoot) {
      // Add the new skill to each parent children
      // TODO: skip this for the root skill as the children of that will always be all skills
      parentSkill.children.push(skillCount);
      parentSkill.nChildren += 1;

      // When we are at an integer power of two steps away from the newly added skill node,
      // add the current parent skill to the new skill's parents array
      if (treeWalkingCounter == powerOfTwo) {
        skills[skillCount].parents.push(parentSkillId);
        powerOfTwo = powerOfTwo*2;
      }

      // Check if we've reached the root of the tree yet (it has no parents)
      // Otherwise get the next parent
      if (parentSkill.nParents == 0) {
        notAtRoot = false;
      } else {
        parentSkillId = parentSkill.parents[0];
        parentSkill = skills[parentSkill.parents[0]];
      }

      treeWalkingCounter += 1;
    }

    emit SkillAdded(skillCount, _parentSkillId);
    return skillCount;
  }

  function getParentSkillId(uint _skillId, uint _parentSkillIndex) public view returns (uint256) {
    return ascendSkillTree(_skillId, _parentSkillIndex + 1);
  }

  function getChildSkillId(uint _skillId, uint _childSkillIndex) public view returns (uint256) {
    Skill storage skill = skills[_skillId];
    return skill.children[_childSkillIndex];
  }

  function appendReputationUpdateLog(address _user, int _amount, uint _skillId) public
  stoppable
  calledByColony
  skillExists(_skillId)
  {
    if (_amount == 0) {
      return;
    }

    uint nParents = skills[_skillId].nParents;
    // We only update child skill reputation if the update is negative, otherwise just set nChildren to 0 to save gas
    uint nChildren = _amount < 0 ? skills[_skillId].nChildren : 0;
    IReputationMiningCycle(inactiveReputationMiningCycle).appendReputationUpdateLog(
      _user,
      _amount,
      _skillId,
      msg.sender,
      nParents,
      nChildren
    );
  }

  function checkNotAdditionalProtectedVariable(uint256 _slot) public view recovery {
  }

  function getFeeInverse() public view returns (uint256 _feeInverse) {
    return feeInverse;
  }

  function setFeeInverse(uint256 _feeInverse) public stoppable
  calledByMetaColony
  {
    require(_feeInverse > 0, "colony-network-fee-inverse-cannot-be-zero");
    feeInverse = _feeInverse;

    emit NetworkFeeInverseSet(_feeInverse);
  }

  function ascendSkillTree(uint _skillId, uint _parentSkillNumber) internal view returns (uint256) {
    if (_parentSkillNumber == 0) {
      return _skillId;
    }

    Skill storage skill = skills[_skillId];
    for (uint i; i < skill.parents.length; i++) {
      if (2**(i+1) > _parentSkillNumber) {
        uint _newSkillId = skill.parents[i];
        uint _newParentSkillNumber = _parentSkillNumber - 2**i;
        return ascendSkillTree(_newSkillId, _newParentSkillNumber);
      }
    }
  }
}
