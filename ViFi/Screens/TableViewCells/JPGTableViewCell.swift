//
//  JPGTableViewCell.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 16.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit

class JPGTableViewCell: UITableViewCell {

    @IBOutlet weak var imegeView: UIImageView!
    
    override func awakeFromNib() {
        super.awakeFromNib()
        // Initialization code
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        // Configure the view for the selected state
    }

}
