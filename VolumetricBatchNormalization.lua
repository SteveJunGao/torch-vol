local BN,parent = torch.class('nn.VolumetricBatchNormalization', 'nn.Module')

function BN:__init(nFeature, eps, momentum, affine)
   parent.__init(self)
   assert(nFeature and type(nFeature) == 'number',
          'Missing argument #1: Number of feature planes. ')
   assert(nFeature ~= 0, 'To set affine=false call VolumetricBatchNormalization'
     .. '(nFeature,  eps, momentum, false) ')
   if affine ~=nil then
      assert(type(affine) == 'boolean', 'affine has to be true/false')
      self.affine = affine
   else
      self.affine = true
   end
   self.eps = eps or 1e-5
   self.train = true
   self.momentum = momentum or 0.1

   self.running_mean = torch.zeros(nFeature)
   self.running_std = torch.ones(nFeature)
   if self.affine then
      self.weight = torch.Tensor(nFeature)
      self.bias = torch.Tensor(nFeature)
      self.gradWeight = torch.Tensor(nFeature)
      self.gradBias = torch.Tensor(nFeature)
      self:reset()
   end
end

function BN:reset()
   self.weight:uniform()
   self.bias:zero()
   self.running_mean:zero()
   self.running_std:fill(1)
end

function BN:updateOutput(input)
   assert(input:dim() == 5, 'only mini-batch supported (5D tensor), got '
             .. input:dim() .. 'D tensor instead')
   local nBatch = input:size(1)
   local nFeature = input:size(2)
   local iT = input:size(3)
   local iH = input:size(4)
   local iW = input:size(5)

   -- buffers that are reused
   self.buffer = self.buffer or input.new()
   self.output:resizeAs(input)
   if self.train == false then
      self.output:copy(input)
      self.buffer:repeatTensor(self.running_mean:view(1, nFeature, 1, 1, 1), nBatch, 1, iT, iH, iW)
      self.output:add(-1, self.buffer)
      self.buffer:repeatTensor(self.running_std:view(1, nFeature, 1, 1, 1), nBatch, 1, iT, iH, iW)
      self.output:cmul(self.buffer)
   else -- training mode
      self.buffer2 = self.buffer2 or input.new()
      self.centered = self.centered or input.new()
      self.centered:resizeAs(input)
      self.std = self.std or input.new()
      self.normalized = self.normalized or input.new()
      self.normalized:resizeAs(input)
      self.gradInput:resizeAs(input)
      -- calculate mean over mini-batch, over feature-maps
      local in_folded = input:view(nBatch, nFeature, iT * iH * iW)
      self.buffer:mean(in_folded, 1)
      self.buffer2:mean(self.buffer, 3)
      self.running_mean:mul(1 - self.momentum):add(self.momentum, self.buffer2) -- add to running mean
      self.buffer:repeatTensor(self.buffer2:view(1, nFeature, 1, 1, 1),
                               nBatch, 1, iT, iH, iW)

      -- subtract mean
      self.centered:add(input, -1, self.buffer)                  -- x - E(x)

      -- calculate standard deviation over mini-batch
      self.buffer:copy(self.centered):cmul(self.buffer)          -- [x - E(x)]^2
      local buf_folded = self.buffer:view(nBatch,nFeature, iT * iH * iW)
      self.std:mean(self.buffer2:mean(buf_folded, 1), 3)
      self.std:add(self.eps):sqrt():pow(-1)      -- 1 / E([x - E(x)]^2)
      self.running_std:mul(1 - self.momentum):add(self.momentum, self.std) -- add to running stdv
      self.buffer:repeatTensor(self.std:view(1, nFeature, 1, 1, 1),
                               nBatch, 1, iT, iH, iW)

      -- divide standard-deviation + eps
      self.output:cmul(self.centered, self.buffer)
      self.normalized:copy(self.output)
   end

   if self.affine then
      -- multiply with gamma and add beta
      self.buffer:repeatTensor(self.weight:view(1, nFeature, 1, 1, 1),
                               nBatch, 1, iT, iH, iW)
      self.output:cmul(self.buffer)
      self.buffer:repeatTensor(self.bias:view(1, nFeature, 1, 1, 1),
                               nBatch, 1, iT, iH, iW)
      self.output:add(self.buffer)
   end

   return self.output
end

function BN:updateGradInput(input, gradOutput)
   assert(input:dim() == 5, 'only mini-batch supported')
   assert(gradOutput:dim() == 5, 'only mini-batch supported')
   assert(self.train == true, 'should be in training mode when self.train is true')
   local nBatch = input:size(1)
   local nFeature = input:size(2)
   local iT = input:size(3)
   local iH = input:size(4)
   local iW = input:size(5)

   self.gradInput:cmul(self.centered, gradOutput)
   local gi_folded = self.gradInput:view(nBatch, nFeature, iT * iH * iW)
   self.buffer2:mean(self.buffer:mean(gi_folded, 1), 3)
   self.gradInput:repeatTensor(self.buffer2:view(1, nFeature, 1, 1, 1),
                               nBatch, 1, iT, iH, iW)
   self.gradInput:cmul(self.centered):mul(-1)
   self.buffer:repeatTensor(self.std:view(1, nFeature, 1, 1, 1),
                            nBatch, 1, iT, iH, iW)
   self.gradInput:cmul(self.buffer):cmul(self.buffer)

   self.buffer:mean(gradOutput:view(nBatch, nFeature, iT * iH * iW), 1)
   self.buffer2:mean(self.buffer, 3)
   self.buffer:repeatTensor(self.buffer2:view(1, nFeature, 1, 1, 1),
                            nBatch, 1, iT, iH, iW)
   self.gradInput:add(gradOutput):add(-1, self.buffer)
   self.buffer:repeatTensor(self.std:view(1, nFeature, 1, 1, 1),
                            nBatch, 1, iT, iH, iW)
   self.gradInput:cmul(self.buffer)

   if self.affine then
      self.buffer:repeatTensor(self.weight:view(1, nFeature, 1, 1, 1),
                               nBatch, 1, iT, iH, iW)
      self.gradInput:cmul(self.buffer)
   end

   return self.gradInput
end

function BN:accGradParameters(input, gradOutput, scale)
   if self.affine then
      scale = scale or 1.0
      local nBatch = input:size(1)
      local nFeature = input:size(2)
      local iT = input:size(3)
      local iH = input:size(4)
      local iW = input:size(5)
      self.buffer2:resizeAs(self.normalized):copy(self.normalized)
      self.buffer2 = self.buffer2:cmul(gradOutput):view(nBatch, nFeature, iT * iH * iW)
      self.buffer:sum(self.buffer2, 1) -- sum over mini-batch
      self.buffer2:sum(self.buffer, 3) -- sum over pixels
      self.gradWeight:add(scale, self.buffer2)

      self.buffer:sum(gradOutput:view(nBatch, nFeature, iT * iH * iW), 1)
      self.buffer2:sum(self.buffer, 3)
      self.gradBias:add(scale, self.buffer2) -- sum over mini-batch
   end
end
